import CMUXMobileCore
import Foundation

/// Projects a connectivity-v2 peer's control lane through the mobile RPC byte seam.
actor CmxConnectivityByteTransport:
    CmxByteTransport,
    CmxByteTransportClosureObserving,
    CmxByteTransportContinuityIdentifying,
    CmxByteTransportSessionPurposeUpdating
{
    private struct ConnectAttempt {
        let id: UUID
        let task: Task<any CmxConnectivitySession, any Error>
    }

    private struct ControlRetirement {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var request: CmxByteTransportRequest
    private let engine: CmxConnectivityEngine
    private let ownerID = UUID()
    private var connectAttempt: ConnectAttempt?
    private var controlRetirement: ControlRetirement?
    private var session: (any CmxConnectivitySession)?
    private var controlAcquisitionStarted = false
    private var ownsControlSession = false
    private var closed = false

    init(request: CmxByteTransportRequest, engine: CmxConnectivityEngine) {
        self.request = request
        self.engine = engine
    }

    func connect() async throws {
        if let controlRetirement {
            await controlRetirement.task.value
        }
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if session != nil { return }

        let attempt: ConnectAttempt
        if let connectAttempt {
            attempt = connectAttempt
        } else {
            let attemptID = UUID()
            let engine = engine
            let request = request
            let ownerID = ownerID
            let task = Task {
                try await engine.acquireControl(
                    for: request,
                    ownerID: ownerID
                )
            }
            attempt = ConnectAttempt(id: attemptID, task: task)
            connectAttempt = attempt
            controlAcquisitionStarted = true
        }

        do {
            let connected = try await withTaskCancellationHandler {
                try await attempt.task.value
            } onCancel: {
                attempt.task.cancel()
                Task { [weak self] in
                    await self?.retireControlSession(
                        reason: .controlOwnerReleased,
                        failure: .cancelled
                    )
                }
            }
            guard !closed, connectAttempt?.id == attempt.id else {
                await retireControlSession(
                    reason: .controlOwnerReleased,
                    failure: .cancelled
                )
                throw CmxIrohByteTransportError.alreadyClosed
            }
            connectAttempt = nil
            controlAcquisitionStarted = false
            ownsControlSession = true
            session = connected
        } catch {
            if connectAttempt?.id == attempt.id {
                connectAttempt = nil
            }
            if Task.isCancelled || error is CancellationError {
                await retireControlSession(
                    reason: .controlOwnerReleased,
                    failure: .cancelled
                )
            } else if controlRetirement == nil {
                // `acquireControl` releases its reservation before throwing.
                controlAcquisitionStarted = false
            }
            throw error
        }
    }

    func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            return try await session.receiveControl(maximumByteCount: 64 * 1_024)
        } catch {
            self.session = nil
            await releaseOwnedControlSession(
                reason: .controlReadFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            try await session.sendControl(data)
        } catch {
            self.session = nil
            await releaseOwnedControlSession(
                reason: .controlWriteFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func close() async {
        if !closed {
            closed = true
            session = nil
            connectAttempt?.task.cancel()
        }
        await retireControlSession(
            reason: .controlOwnerReleased,
            failure: .none
        )
    }

    func transportContinuityID() async -> UInt64? {
        await session?.connectionContinuityID()
    }

    func transportClosureObservation() -> CmxTransportClosureObservation? {
        guard let session else { return nil }
        return CmxTransportClosureObservation {
            await session.waitUntilClosed()
        }
    }

    func updateSessionPurpose(_ purpose: CmxTransportSessionPurpose) async {
        guard request.sessionPurpose != purpose else { return }
        request = request.withSessionPurpose(purpose)
        guard ownsControlSession else { return }
        await engine.updateControlPurpose(
            for: request,
            ownerID: ownerID,
            purpose: purpose
        )
    }

    private func releaseOwnedControlSession(
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        await retireControlSession(reason: reason, failure: failure)
    }

    private func retireControlSession(
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        if let controlRetirement {
            await controlRetirement.task.value
            return
        }
        guard ownsControlSession || controlAcquisitionStarted else { return }
        connectAttempt?.task.cancel()
        connectAttempt = nil
        ownsControlSession = false
        controlAcquisitionStarted = false
        let retirementID = UUID()
        let engine = engine
        let request = request
        let ownerID = ownerID
        let task = Task {
            await engine.releaseControl(
                for: request,
                ownerID: ownerID,
                reason: reason,
                failure: failure
            )
        }
        controlRetirement = ControlRetirement(
            id: retirementID,
            task: task
        )
        await task.value
        if controlRetirement?.id == retirementID {
            controlRetirement = nil
        }
    }
}
