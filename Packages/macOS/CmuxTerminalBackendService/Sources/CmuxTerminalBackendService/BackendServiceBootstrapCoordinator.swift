internal import Foundation

/// Owns registration and explicit teardown for the persistent backend.
///
/// Registration, status lookup, and bundle filesystem work run on this actor
/// instead of the main actor. Re-registering an enabled service is deliberately
/// avoided because cycling it would terminate backend-owned PTYs.
public actor BackendServiceBootstrapCoordinator {
    private let activationPolicy: BackendServiceActivationPolicy
    private let inspection: BackendServiceBundleInspection
    private let registration: any BackendServiceRegistration
    private let readinessChecker: any BackendServiceReadinessChecking
    private var state: BackendServiceRuntimeState
    private var continuations: [UUID: AsyncStream<BackendServiceRuntimeState>.Continuation] = [:]
    private var currentOperationID = UUID()
    private var ensureOperationID: UUID?
    private var ensureTask: Task<BackendServiceBootstrapResult, any Error>?
    private var bestEffortStagingTask: Task<Void, Never>?
    private var unregistering = false

    /// Creates a testable backend bootstrap coordinator.
    ///
    /// - Parameters:
    ///   - activationPolicy: The feature gate for this process.
    ///   - inspection: The app-bundle artifact validator.
    ///   - registration: The service-management registration adapter.
    ///   - readinessChecker: The protocol-level launch readiness probe.
    public init(
        activationPolicy: BackendServiceActivationPolicy,
        inspection: BackendServiceBundleInspection,
        registration: any BackendServiceRegistration,
        readinessChecker: any BackendServiceReadinessChecking
    ) {
        self.activationPolicy = activationPolicy
        self.inspection = inspection
        self.registration = registration
        self.readinessChecker = readinessChecker
        state = activationPolicy.isEnabled ? .checking : .disabled
    }

    /// Returns an immediately seeded stream of lifecycle changes.
    ///
    /// - Returns: A newest-value stream that ends when its consumer releases it.
    public func stateUpdates() -> AsyncStream<BackendServiceRuntimeState> {
        let identifier = UUID()
        let pair = AsyncStream<BackendServiceRuntimeState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.yield(state)
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(identifier) }
        }
        return pair.stream
    }

    /// The most recently published lifecycle state.
    public func currentState() -> BackendServiceRuntimeState {
        state
    }

    /// Ensures the launch agent is registered without cycling an enabled service.
    ///
    /// - Returns: The bootstrap outcome.
    /// - Throws: The registration error when ServiceManagement rejects the request.
    public func ensureRegistered() async throws -> BackendServiceBootstrapResult {
        guard !unregistering else { throw CancellationError() }
        if let ensureTask { return try await ensureTask.value }

        let operationID = UUID()
        currentOperationID = operationID
        ensureOperationID = operationID
        let task = Task { try await self.performEnsure(operationID: operationID) }
        ensureTask = task
        do {
            let result = try await task.value
            clearEnsureTask(operationID: operationID)
            return result
        } catch {
            clearEnsureTask(operationID: operationID)
            throw error
        }
    }

    private func performEnsure(operationID: UUID) async throws -> BackendServiceBootstrapResult {
        try requireCurrent(operationID)
        guard activationPolicy.isEnabled else {
            try publish(.disabled, operationID: operationID)
            return .disabled
        }

        try publish(.checking, operationID: operationID)
        let initialStatus = try await registration.status()
        try requireCurrent(operationID)
        switch initialStatus {
        case .enabled:
            let result = try await verifyReadinessForActivePair(operationID: operationID)
            if case .ready = result {
                beginBestEffortCurrentBundleStaging()
            }
            return result
        case .requiresApproval:
            try publish(.requiresApproval, operationID: operationID)
            return .requiresApproval
        case .notFound:
            try publish(.unavailable(.serviceNotFound), operationID: operationID)
            return .serviceNotFound
        case .notRegistered:
            if let missing = inspection.firstMissingItem() {
                try publish(.unavailable(.missingBundleItem(missing)), operationID: operationID)
                return .missingBundleItem(missing)
            }

            let preparedPair: BackendServiceInstalledPair
            do {
                preparedPair = try await registration.prepareBundledPair()
            } catch {
                try requireCurrent(operationID)
                try publish(.unavailable(.pairValidationFailed), operationID: operationID)
                return .backendUnavailable
            }
            do {
                try await registration.register(preparedPair)
            } catch {
                try requireCurrent(operationID)
                try publish(.unavailable(.registrationFailed), operationID: operationID)
                throw error
            }
            try requireCurrent(operationID)
            let registeredStatus = try await registration.status()
            try requireCurrent(operationID)
            switch registeredStatus {
            case .enabled:
                return try await verifyReadinessForActivePair(operationID: operationID)
            case .requiresApproval:
                try publish(.requiresApproval, operationID: operationID)
                return .requiresApproval
            case .notFound:
                try publish(.unavailable(.serviceNotFound), operationID: operationID)
                return .serviceNotFound
            case .notRegistered:
                // Status propagation can lag registration. Probe the socket
                // instead of treating launch eligibility as protocol health.
                return try await verifyReadiness(
                    trustedPair: preparedPair,
                    operationID: operationID
                )
            }
        }
    }

    /// Explicitly unregisters the service and waits for backend termination.
    ///
    /// This operation terminates every PTY owned by the backend process. It is
    /// intended for app removal and tagged-build cleanup, not normal app exit.
    ///
    /// - Returns: Whether a service was removed or already absent.
    /// - Throws: The unregistration error from ServiceManagement.
    public func unregister() async throws -> BackendServiceUnregisterResult {
        guard !unregistering else { throw CancellationError() }
        unregistering = true
        defer { unregistering = false }
        ensureTask?.cancel()
        ensureTask = nil
        ensureOperationID = nil
        let operationID = UUID()
        currentOperationID = operationID

        let status = try await registration.status()
        guard currentOperationID == operationID else { throw CancellationError() }
        switch status {
        case .notRegistered:
            publish(.unregistered)
            return .alreadyUnregistered
        case .notFound:
            publish(.unavailable(.serviceNotFound))
            return .serviceNotFound
        case .enabled, .requiresApproval:
            publish(.unregistering)
            do {
                try await registration.unregister()
            } catch {
                publish(.unavailable(.unregistrationFailed))
                throw error
            }
            publish(.unregistered)
            return .unregistered
        }
    }

    /// Opens System Settings at the Login Items service-approval UI.
    public func openSystemSettingsLoginItems() async {
        await registration.openSystemSettingsLoginItems()
    }

    private func publish(_ newState: BackendServiceRuntimeState) {
        state = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    private func publish(
        _ newState: BackendServiceRuntimeState,
        operationID: UUID
    ) throws {
        try requireCurrent(operationID)
        publish(newState)
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    private func verifyReadinessForActivePair(
        operationID: UUID
    ) async throws -> BackendServiceBootstrapResult {
        do {
            guard let activePair = try await registration.activeInstalledPair() else {
                try publish(.unavailable(.pairValidationFailed), operationID: operationID)
                return .backendUnavailable
            }
            return try await verifyReadiness(
                trustedPair: activePair,
                operationID: operationID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try publish(.unavailable(.pairValidationFailed), operationID: operationID)
            return .backendUnavailable
        }
    }

    private func verifyReadiness(
        trustedPair: BackendServiceInstalledPair,
        operationID: UUID
    ) async throws -> BackendServiceBootstrapResult {
        try publish(.launching, operationID: operationID)
        do {
            let readiness = try await readinessChecker.checkReadiness(
                trustedPair: trustedPair
            )
            try publish(.ready(readiness), operationID: operationID)
            return .ready(readiness)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try publish(.unavailable(.readinessFailed), operationID: operationID)
            return .backendUnavailable
        }
    }

    private func requireCurrent(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard currentOperationID == operationID else { throw CancellationError() }
    }

    private func clearEnsureTask(operationID: UUID) {
        guard ensureOperationID == operationID else { return }
        ensureTask = nil
        ensureOperationID = nil
    }

    private func beginBestEffortCurrentBundleStaging() {
        guard bestEffortStagingTask == nil else { return }
        let registration = registration
        let task = Task { [weak self] in
            _ = try? await registration.prepareBundledPair()
            await self?.clearBestEffortStagingTask()
        }
        bestEffortStagingTask = task
    }

    private func clearBestEffortStagingTask() {
        bestEffortStagingTask = nil
    }
}
