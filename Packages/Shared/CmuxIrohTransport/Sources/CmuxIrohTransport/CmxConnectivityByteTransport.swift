import CMUXMobileCore
import Foundation

/// Projects a connectivity-v2 peer's control lane through the mobile RPC byte seam.
actor CmxConnectivityByteTransport:
    CmxByteTransport,
    CmxByteTransportClosureObserving,
    CmxByteTransportContinuityIdentifying,
    CmxByteTransportDiagnosticSessionIdentifying,
    CmxByteTransportSessionPurposeUpdating
{
    private var request: CmxByteTransportRequest
    private let engine: CmxConnectivityEngine
    private let ownerID = UUID()
    private var session: (any CmxConnectivitySession)?
    private var ownsControlSession = false
    private var closed = false

    init(request: CmxByteTransportRequest, engine: CmxConnectivityEngine) {
        self.request = request
        self.engine = engine
    }

    func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if session != nil { return }
        let connected = try await engine.acquireControl(
            for: request,
            ownerID: ownerID
        )
        guard !closed else {
            await engine.releaseControl(for: request, ownerID: ownerID)
            throw CmxIrohByteTransportError.alreadyClosed
        }
        ownsControlSession = true
        session = connected
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
        guard !closed else { return }
        closed = true
        session = nil
        await releaseOwnedControlSession(
            reason: .controlOwnerReleased,
            failure: .none
        )
    }

    func transportContinuityID() async -> UInt64? {
        await session?.connectionContinuityID()
    }

    func transportDiagnosticSessionID() async -> Int? {
        await engine.diagnosticSessionID(for: request)
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
        guard ownsControlSession else { return }
        ownsControlSession = false
        await engine.releaseControl(
            for: request,
            ownerID: ownerID,
            reason: reason,
            failure: failure
        )
    }
}
