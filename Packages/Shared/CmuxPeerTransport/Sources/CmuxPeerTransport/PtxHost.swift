import Foundation
import IrohLib

/// One admitted host-side session.
public struct PtxHostSession: Sendable {
    public let sessionID: String
    public let connection: PtxConnection
    public let control: PtxFrameChannel
    public let grant: PtxGrant
    public let remoteKey: Data
}

/// The Mac-side admission service: accepts connections, judges grants, admits
/// or closes with a reason code, supersedes older sessions for the same
/// (device, app) immediately, and runs each session's control-lane consumer
/// (ping echo). Application traffic is handed off through `onAdmitted` and
/// rides raw streams; this actor never touches them.
public actor PtxHost {
    public struct Configuration: Sendable {
        public var admissionTimeout: Duration = .seconds(10)
        /// Bound grant lifetimes only; expiry mid-session is NOT enforced by
        /// teardown in v1 (grants live days; re-admission renews).
        public var grantLifetime: TimeInterval = 30 * 24 * 3600

        public init() {}
    }

    private let identity: PtxIdentity
    private let signer: PtxGrantSigner
    private let verifier: PtxGrantVerifier
    private let log: PtxEventLog
    private let configuration: Configuration
    private let onAdmitted: @Sendable (PtxHostSession) async -> Void
    private let onSessionEnded: @Sendable (PtxHostSession, String?) async -> Void

    private var acceptTask: Task<Void, Never>?
    /// Keyed by (deviceID, appIdentity): the supersession identity.
    private var sessions: [String: PtxHostSession] = [:]
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var sessionCounter = 0
    private var revokedGrantIDs: Set<String> = []

    public init(
        identity: PtxIdentity, signer: PtxGrantSigner, log: PtxEventLog,
        configuration: Configuration = Configuration(),
        onAdmitted: @escaping @Sendable (PtxHostSession) async -> Void,
        onSessionEnded: @escaping @Sendable (PtxHostSession, String?) async -> Void = { _, _ in }
    ) {
        self.identity = identity
        self.signer = signer
        self.verifier = PtxGrantVerifier(trustedSignerKey: signer.publicKeyData)
        self.log = log
        self.configuration = configuration
        self.onAdmitted = onAdmitted
        self.onSessionEnded = onSessionEnded
    }

    /// Mints a grant for a phone (served over the pair RPC on the legacy
    /// authenticated channel).
    public func mintGrant(
        account: String, deviceID: String, devicePublicKey: Data, appIdentity: String
    ) throws -> PtxGrant {
        try signer.mint(
            account: account, deviceID: deviceID, devicePublicKey: devicePublicKey,
            appIdentity: appIdentity, lifetime: configuration.grantLifetime)
    }

    public func revokeGrant(id: String) {
        revokedGrantIDs.insert(id)
    }

    public func activeSessionCount() -> Int {
        sessions.count
    }

    /// Accept loop for the endpoint's lifetime. Accept failures retry with a
    /// short ladder instead of killing the host (a transient accept error
    /// must never take down every existing session).
    public func serve(endpoint: sending IrohEndpointBox) {
        guard acceptTask == nil else { return }
        acceptTask = Task { [weak self, log] in
            var failureDelay = 0.1
            while !Task.isCancelled {
                do {
                    guard let self,
                        let connection = try await PtxEndpoint.acceptOne(
                            endpoint: endpoint.endpoint, log: log)
                    else { return }
                    failureDelay = 0.1
                    Task { await self.admit(connection: connection) }
                } catch {
                    log.emit(
                        PtxEventKind.frameError, reason: "accept-failed",
                        detail: ["error": String(describing: error)])
                    try? await Task.sleep(for: .seconds(failureDelay))
                    failureDelay = min(failureDelay * 2, 5)
                }
            }
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        for (key, session) in sessions {
            watchTasks[key]?.cancel()
            await session.connection.close(reason: PtxCloseReason.hostStopping.rawValue)
        }
        sessions.removeAll()
        watchTasks.removeAll()
    }

    private func admit(connection: PtxConnection) async {
        let start = ContinuousClock.now
        let remoteKey = connection.authenticatedRemoteKey
        log.emit(PtxEventKind.admissionStart, peer: remoteKey)
        do {
            let session = try await withTimeout(
                configuration.admissionTimeout,
                onAbandoned: { (session: PtxHostSession) in
                    await session.connection.close(
                        reason: PtxCloseReason.admissionTimeout.rawValue)
                }
            ) { [weak self] in
                guard let self else { throw PtxTransportError.connectionClosed }
                return try await self.performAdmission(connection: connection)
            }
            log.emit(
                PtxEventKind.admissionAdmitted, peer: remoteKey, session: session.sessionID,
                ms: log.elapsedMs(since: start),
                detail: ["device": session.grant.deviceID, "app": session.grant.appIdentity])
            await onAdmitted(session)
        } catch let denial as PtxDenialError {
            log.emit(
                PtxEventKind.admissionDenied, peer: remoteKey, reason: denial.code.rawValue,
                ms: log.elapsedMs(since: start))
            await connection.close(reason: denial.code.rawValue)
        } catch {
            log.emit(
                PtxEventKind.admissionDenied, peer: remoteKey, reason: "admission-error",
                ms: log.elapsedMs(since: start),
                detail: ["error": String(describing: error)])
            await connection.close(reason: PtxCloseReason.admissionTimeout.rawValue)
        }
    }

    private struct PtxDenialError: Error {
        var code: PtxDenial
    }

    private func performAdmission(connection: PtxConnection) async throws -> PtxHostSession {
        guard let control = await connection.acceptedControlLane(),
            let hello = await control.receiveFrame()
        else { throw PtxTransportError.connectionClosed }
        guard hello.type == PtxFrameType.hello,
            let protocolID = hello.payload["protocol"]?.stringValue,
            let deviceID = hello.payload["device_id"]?.stringValue,
            let app = hello.payload["app"]?.stringValue,
            let key = hello.payload["key"]?.dataValue,
            let grantPayload = hello.payload["grant"],
            let grant = PtxGrant(payload: grantPayload)
        else { throw PtxDenialError(code: .malformedHello) }
        guard protocolID == PtxProtocol.identifier else {
            throw PtxDenialError(code: .protocolMismatch)
        }
        let remoteKey = connection.authenticatedRemoteKey
        guard key == remoteKey else { throw PtxDenialError(code: .keyMismatch) }
        var verifier = self.verifier
        verifier.revokedGrantIDs = revokedGrantIDs
        if let denial = verifier.decide(
            grant: grant, remoteKey: remoteKey, helloDeviceID: deviceID, helloApp: app)
        {
            throw PtxDenialError(code: denial)
        }

        // Immediate supersession: same (device, app) replaces its old session
        // now, not after a lockout (the ~85s legacy lockout, issue 10372).
        let supersessionKey = "\(deviceID)|\(app)"
        if let existing = sessions[supersessionKey] {
            watchTasks[supersessionKey]?.cancel()
            log.emit(
                PtxEventKind.sessionEnd, session: existing.sessionID,
                reason: PtxCloseReason.superseded.rawValue,
                detail: ["supersededBy": "new-admission", "device": deviceID])
            await existing.connection.close(reason: PtxCloseReason.superseded.rawValue)
            await onSessionEnded(existing, PtxCloseReason.superseded.rawValue)
        }

        sessionCounter += 1
        let sessionID = "s\(sessionCounter)"
        try await control.sendFrame(
            PtxFrame(type: PtxFrameType.admit, payload: ["session": .string(sessionID)]))
        let session = PtxHostSession(
            sessionID: sessionID, connection: connection, control: control,
            grant: grant, remoteKey: remoteKey)
        sessions[supersessionKey] = session
        startWatch(key: supersessionKey, session: session)
        return session
    }

    /// Host-side single control-lane consumer: ping echo + termination watch.
    private func startWatch(key: String, session: PtxHostSession) {
        watchTasks[key]?.cancel()
        watchTasks[key] = Task { [weak self, log] in
            while !Task.isCancelled {
                guard let frame = await session.control.receiveFrame() else { break }
                switch frame.type {
                case PtxFrameType.ping:
                    try? await session.control.sendFrame(
                        PtxFrame(type: PtxFrameType.pong, payload: frame.payload))
                case PtxFrameType.pong:
                    break
                default:
                    if !frame.type.hasPrefix(PtxFrameType.optionalPrefix) {
                        log.emit(
                            PtxEventKind.frameError, session: session.sessionID,
                            reason: "unknown-frame", detail: ["type": frame.type])
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let cause = await session.connection.termination()
            await self?.noteSessionEnded(key: key, session: session, cause: cause)
        }
    }

    private func noteSessionEnded(key: String, session: PtxHostSession, cause: String?) async {
        guard sessions[key]?.sessionID == session.sessionID else { return }
        sessions[key] = nil
        watchTasks[key] = nil
        log.emit(
            PtxEventKind.sessionEnd, session: session.sessionID,
            reason: cause ?? "unattributed-connection-end",
            detail: ["observer": "host", "device": session.grant.deviceID])
        await onSessionEnded(session, cause)
    }

    /// Everything a phone needs to dial us. Direct addresses are the LAN
    /// interface IPs (loopback-rewritten wildcards are dialable only from the
    /// same machine — a legacy field bug).
    public func ticket(
        relayURL: String?, lanAddresses: [String]
    ) -> PtxTicket {
        PtxTicket(
            hostEndpointKey: identity.publicKeyData,
            hostSignerKey: signer.publicKeyData,
            hostDeviceID: identity.deviceID,
            relayURL: relayURL,
            directAddresses: lanAddresses)
    }
}
