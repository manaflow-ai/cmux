public import CmuxTerminalBackend
public import Foundation

/// Exact immutable pair and exact launch-agent bytes observed under the service lock.
internal struct BackendServiceHandoffLaunchDescriptor: Equatable, Sendable {
    let pair: BackendServiceInstalledPair
    let propertyListData: Data
}

internal protocol BackendServiceHandoffRegistering: Sendable {
    func prepareBundledPair() async throws -> BackendServiceInstalledPair
    func activeHandoffDescriptor() async throws -> BackendServiceHandoffLaunchDescriptor?
    func bootoutExact(_ descriptor: BackendServiceHandoffLaunchDescriptor) async throws
    func writeHandoffDescriptor(
        for pair: BackendServiceInstalledPair
    ) async throws -> BackendServiceHandoffLaunchDescriptor
    func restoreHandoffDescriptor(
        _ descriptor: BackendServiceHandoffLaunchDescriptor
    ) async throws
    func bootstrapExact(_ descriptor: BackendServiceHandoffLaunchDescriptor) async throws
}

internal protocol BackendServiceHandoffConnecting: Sendable {
    func connect(trustedPair: BackendServiceInstalledPair) async throws
    func prepare(targetBuildID: String) async throws -> BackendServiceHandoffPreparation
    func revalidate(_ permit: BackendServiceHandoffPermit) async throws
    func cancel(_ permit: BackendServiceHandoffPermit) async throws
    func close() async
}

internal protocol BackendServiceHandoffLockLease: Sendable {
    func release() async
}

internal protocol BackendServiceHandoffLocking: Sendable {
    func acquire() async throws -> any BackendServiceHandoffLockLease
}

/// A typed step failure that preserves whether activation or rollback failed.
public struct BackendServiceHandoffFailure: Error, Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case stageTarget
        case loadOldDescriptor
        case connectCoordinator
        case preparePermit
        case validatePermit
        case acquireLock
        case revalidateOldDescriptor
        case revalidatePermit
        case bootoutOldDescriptor
        case writeNewDescriptor
        case bootstrapNewDescriptor
        case proveNewReadiness
        case revalidateNewDescriptor
        case bootoutNewDescriptor
        case restoreOldDescriptor
        case bootstrapOldDescriptor
        case proveOldReadiness
        case cancelPermit
    }

    public let stage: Stage
    public let detail: String

    public init(stage: Stage, detail: String) {
        self.stage = stage
        self.detail = detail
    }
}

/// End-to-end outcome of one staged backend activation attempt.
public enum BackendServiceHandoffResult: Equatable, Sendable {
    case deferredNotIdle(BackendServiceHandoffBlockers)
    case activated(BackendServiceReadiness)
    case rolledBack(BackendServiceHandoffFailure, BackendServiceReadiness?)
    case rollbackFailed(BackendServiceHandoffFailure, BackendServiceHandoffFailure)
}

/// Replaces an idle backend under an authenticated daemon permit and a private file lock.
public actor BackendServiceHandoffCoordinator {
    private let registration: any BackendServiceHandoffRegistering
    private let connection: any BackendServiceHandoffConnecting
    private let lock: any BackendServiceHandoffLocking
    private let readinessChecker: any BackendServiceReadinessChecking
    private let expectedSession: String
    private var operationInFlight = false

    /// Creates the production authenticated handoff transaction.
    public init(
        descriptor: BackendServiceDescriptor,
        runtimePaths: BackendServiceRuntimePaths,
        registration: SystemBackendServiceRegistration,
        readinessChecker: any BackendServiceReadinessChecking,
        processInstanceUUID: UUID,
        userID: UInt32
    ) {
        self.registration = registration
        connection = BackendServiceProtocolHandoffConnection(
            descriptor: descriptor,
            runtimePaths: runtimePaths,
            processInstanceUUID: processInstanceUUID,
            expectedUserID: userID
        )
        lock = SystemBackendServiceHandoffLock(
            runtimePaths: runtimePaths,
            expectedUserID: userID
        )
        self.readinessChecker = readinessChecker
        expectedSession = descriptor.sessionName
    }

    internal init(
        registration: any BackendServiceHandoffRegistering,
        connection: any BackendServiceHandoffConnecting,
        lock: any BackendServiceHandoffLocking,
        readinessChecker: any BackendServiceReadinessChecking,
        expectedSession: String = "cmux"
    ) {
        self.registration = registration
        self.connection = connection
        self.lock = lock
        self.readinessChecker = readinessChecker
        self.expectedSession = expectedSession
    }

    /// Stages the bundled pair, asks vN to drain, and activates vN+1 with exact rollback.
    public func activateStagedPairIfIdle() async throws -> BackendServiceHandoffResult {
        guard !operationInFlight else { throw CancellationError() }
        operationInFlight = true
        defer { operationInFlight = false }

        let target: BackendServiceInstalledPair
        do {
            target = try await registration.prepareBundledPair()
        } catch {
            return .rolledBack(failure(.stageTarget, error), nil)
        }

        let original: BackendServiceHandoffLaunchDescriptor
        do {
            guard let loaded = try await registration.activeHandoffDescriptor() else {
                return .rolledBack(
                    BackendServiceHandoffFailure(
                        stage: .loadOldDescriptor,
                        detail: "no active launch descriptor"
                    ),
                    nil
                )
            }
            original = loaded
        } catch {
            return .rolledBack(failure(.loadOldDescriptor, error), nil)
        }

        if original.pair.buildID == target.buildID {
            do {
                return .activated(try await readinessChecker.checkReadiness(trustedPair: original.pair))
            } catch {
                return .rolledBack(failure(.proveOldReadiness, error), nil)
            }
        }

        do {
            try await connection.connect(trustedPair: original.pair)
        } catch {
            await connection.close()
            return .rolledBack(failure(.connectCoordinator, error), nil)
        }

        let preparation: BackendServiceHandoffPreparation
        do {
            preparation = try await connection.prepare(targetBuildID: target.buildID)
        } catch {
            await connection.close()
            return .rolledBack(failure(.preparePermit, error), nil)
        }
        switch preparation {
        case .deferredNotIdle(let blockers):
            await connection.close()
            return .deferredNotIdle(blockers)
        case .prepared(let permit):
            return await activate(
                target: target,
                original: original,
                permit: permit
            )
        }
    }

    private func activate(
        target: BackendServiceInstalledPair,
        original: BackendServiceHandoffLaunchDescriptor,
        permit: BackendServiceHandoffPermit
    ) async -> BackendServiceHandoffResult {
        guard permit.sourceBuildID == original.pair.buildID,
              permit.targetBuildID == target.buildID,
              permit.session == expectedSession,
              permit.durableStorage.state != .degraded,
              !permit.durableStorage.unresolvedMutation,
              permit.durableStorage.unresolvedLaunchAttempts == 0
        else {
            let invalid = BackendServiceHandoffFailure(
                stage: .validatePermit,
                detail: "daemon permit does not bind the exact eligible source and target"
            )
            let cancellationFailure = await cancelPermit(permit)
            await connection.close()
            return cancellationFailure.map { .rollbackFailed(invalid, $0) }
                ?? .rolledBack(invalid, nil)
        }

        let lease: any BackendServiceHandoffLockLease
        do {
            lease = try await lock.acquire()
        } catch {
            let activationFailure = failure(.acquireLock, error)
            let cancellationFailure = await cancelPermit(permit)
            await connection.close()
            return cancellationFailure.map { .rollbackFailed(activationFailure, $0) }
                ?? .rolledBack(activationFailure, nil)
        }

        let result = await activateUnderLock(
            target: target,
            original: original,
            permit: permit
        )
        await lease.release()
        await connection.close()
        return result
    }

    private func activateUnderLock(
        target: BackendServiceInstalledPair,
        original: BackendServiceHandoffLaunchDescriptor,
        permit: BackendServiceHandoffPermit
    ) async -> BackendServiceHandoffResult {
        do {
            guard try await registration.activeHandoffDescriptor() == original else {
                throw BackendServiceHandoffFailure(
                    stage: .revalidateOldDescriptor,
                    detail: "loaded vN descriptor changed while waiting for the service lock"
                )
            }
        } catch {
            let activationFailure = normalizedFailure(.revalidateOldDescriptor, error)
            return await cancelBeforeBootout(permit, activationFailure: activationFailure)
        }

        do {
            try await connection.revalidate(permit)
        } catch {
            let activationFailure = normalizedFailure(.revalidatePermit, error)
            return await cancelBeforeBootout(permit, activationFailure: activationFailure)
        }

        do {
            try await registration.bootoutExact(original)
        } catch {
            let activationFailure = normalizedFailure(.bootoutOldDescriptor, error)
            return await recoverAfterAmbiguousOldBootout(
                permit,
                activationFailure: activationFailure,
                original: original
            )
        }

        let replacement: BackendServiceHandoffLaunchDescriptor
        do {
            replacement = try await registration.writeHandoffDescriptor(for: target)
        } catch {
            return await rollBack(
                activationFailure: failure(.writeNewDescriptor, error),
                original: original,
                expectedReplacement: nil
            )
        }

        do {
            try await registration.bootstrapExact(replacement)
        } catch {
            return await rollBack(
                activationFailure: failure(.bootstrapNewDescriptor, error),
                original: original,
                expectedReplacement: replacement
            )
        }

        do {
            let readiness = try await readinessChecker.checkReadiness(trustedPair: target)
            try validateNewReadiness(readiness, permit: permit)
            return .activated(readiness)
        } catch {
            return await rollBack(
                activationFailure: normalizedFailure(.proveNewReadiness, error),
                original: original,
                expectedReplacement: replacement
            )
        }
    }

    private func cancelBeforeBootout(
        _ permit: BackendServiceHandoffPermit,
        activationFailure: BackendServiceHandoffFailure
    ) async -> BackendServiceHandoffResult {
        if let cancellationFailure = await cancelPermit(permit) {
            return .rollbackFailed(activationFailure, cancellationFailure)
        }
        return .rolledBack(activationFailure, nil)
    }

    private func recoverAfterAmbiguousOldBootout(
        _ permit: BackendServiceHandoffPermit,
        activationFailure: BackendServiceHandoffFailure,
        original: BackendServiceHandoffLaunchDescriptor
    ) async -> BackendServiceHandoffResult {
        let active: BackendServiceHandoffLaunchDescriptor?
        do {
            active = try await registration.activeHandoffDescriptor()
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.revalidateOldDescriptor, error)
            )
        }
        if active == original {
            return await cancelBeforeBootout(permit, activationFailure: activationFailure)
        }
        guard active == nil else {
            return .rollbackFailed(
                activationFailure,
                BackendServiceHandoffFailure(
                    stage: .revalidateOldDescriptor,
                    detail: "a racing launch descriptor replaced vN during bootout"
                )
            )
        }
        return await rollBack(
            activationFailure: activationFailure,
            original: original,
            expectedReplacement: nil
        )
    }

    private func cancelPermit(
        _ permit: BackendServiceHandoffPermit
    ) async -> BackendServiceHandoffFailure? {
        do {
            try await connection.cancel(permit)
            return nil
        } catch {
            return failure(.cancelPermit, error)
        }
    }

    private func rollBack(
        activationFailure: BackendServiceHandoffFailure,
        original: BackendServiceHandoffLaunchDescriptor,
        expectedReplacement: BackendServiceHandoffLaunchDescriptor?
    ) async -> BackendServiceHandoffResult {
        let active: BackendServiceHandoffLaunchDescriptor?
        do {
            active = try await registration.activeHandoffDescriptor()
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.revalidateNewDescriptor, error)
            )
        }

        if let active {
            if active == original {
                return await proveRestoredOriginal(
                    activationFailure: activationFailure,
                    original: original
                )
            }
            guard let expectedReplacement, active == expectedReplacement else {
                return .rollbackFailed(
                    activationFailure,
                    BackendServiceHandoffFailure(
                        stage: .revalidateNewDescriptor,
                        detail: "a racing launch descriptor replaced the exact staged build"
                    )
                )
            }
            do {
                try await registration.bootoutExact(expectedReplacement)
            } catch {
                return await recoverAfterAmbiguousNewBootout(
                    activationFailure: activationFailure,
                    bootoutFailure: normalizedFailure(.bootoutNewDescriptor, error),
                    original: original,
                    expectedReplacement: expectedReplacement
                )
            }
        }

        do {
            try await registration.restoreHandoffDescriptor(original)
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.restoreOldDescriptor, error)
            )
        }
        do {
            try await registration.bootstrapExact(original)
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.bootstrapOldDescriptor, error)
            )
        }
        return await proveRestoredOriginal(
            activationFailure: activationFailure,
            original: original
        )
    }

    private func recoverAfterAmbiguousNewBootout(
        activationFailure: BackendServiceHandoffFailure,
        bootoutFailure: BackendServiceHandoffFailure,
        original: BackendServiceHandoffLaunchDescriptor,
        expectedReplacement: BackendServiceHandoffLaunchDescriptor
    ) async -> BackendServiceHandoffResult {
        let active: BackendServiceHandoffLaunchDescriptor?
        do {
            active = try await registration.activeHandoffDescriptor()
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.revalidateNewDescriptor, error)
            )
        }
        if active == original {
            return await proveRestoredOriginal(
                activationFailure: activationFailure,
                original: original
            )
        }
        if active == expectedReplacement {
            return .rollbackFailed(activationFailure, bootoutFailure)
        }
        guard active == nil else {
            return .rollbackFailed(
                activationFailure,
                BackendServiceHandoffFailure(
                    stage: .revalidateNewDescriptor,
                    detail: "a racing launch descriptor replaced the exact staged build"
                )
            )
        }

        do {
            try await registration.restoreHandoffDescriptor(original)
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.restoreOldDescriptor, error)
            )
        }
        do {
            try await registration.bootstrapExact(original)
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.bootstrapOldDescriptor, error)
            )
        }
        return await proveRestoredOriginal(
            activationFailure: activationFailure,
            original: original
        )
    }

    private func proveRestoredOriginal(
        activationFailure: BackendServiceHandoffFailure,
        original: BackendServiceHandoffLaunchDescriptor
    ) async -> BackendServiceHandoffResult {
        do {
            let readiness = try await readinessChecker.checkReadiness(trustedPair: original.pair)
            return .rolledBack(activationFailure, readiness)
        } catch {
            return .rollbackFailed(
                activationFailure,
                normalizedFailure(.proveOldReadiness, error)
            )
        }
    }

    private func validateNewReadiness(
        _ readiness: BackendServiceReadiness,
        permit: BackendServiceHandoffPermit
    ) throws {
        guard readiness.session == permit.session,
              readiness.authority.sessionID == permit.authority.sessionID,
              readiness.authority.daemonInstanceID != permit.authority.daemonInstanceID,
              readiness.topologyRevision >= permit.canonicalTopologyRevision
        else {
            throw BackendServiceHandoffFailure(
                stage: .proveNewReadiness,
                detail: "replacement readiness does not continue the permitted session"
            )
        }
    }

    private func failure(
        _ stage: BackendServiceHandoffFailure.Stage,
        _ error: any Error
    ) -> BackendServiceHandoffFailure {
        BackendServiceHandoffFailure(stage: stage, detail: String(describing: error))
    }

    private func normalizedFailure(
        _ stage: BackendServiceHandoffFailure.Stage,
        _ error: any Error
    ) -> BackendServiceHandoffFailure {
        (error as? BackendServiceHandoffFailure) ?? failure(stage, error)
    }
}
