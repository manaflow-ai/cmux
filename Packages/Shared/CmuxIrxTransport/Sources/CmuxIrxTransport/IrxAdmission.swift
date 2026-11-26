public import Foundation
public import IrohLib

/// Admission outcome carried into the host: the peer tuple the grant proved,
/// bound to the TLS-authenticated key by the verifier closure.
public struct IrxAdmittedPeerInfo: Equatable, Sendable {
    public var bindingID: String
    public var deviceID: String
    public var tag: String
    public var endpointIDHex: String
    public var identityGeneration: Int

    public init(
        bindingID: String,
        deviceID: String,
        tag: String,
        endpointIDHex: String,
        identityGeneration: Int
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.tag = tag
        self.endpointIDHex = endpointIDHex
        self.identityGeneration = identityGeneration
    }
}

public struct IrxAdmissionDenied: Error, Equatable, Sendable {
    public var code: IrxCloseCode

    public init(code: IrxCloseCode) {
        self.code = code
    }
}

/// Admission judgment seam: given the (optional) presented grant JWS and the
/// TLS-proved remote key, either return the admitted peer tuple or throw
/// ``IrxAdmissionDenied``. The list judge ignores the grant entirely; the
/// legacy grant judge requires one. Deliberately OFFLINE (no backend call
/// sits on the admission path - revocations enforce via the pushed device
/// list, or at the next admission).
public typealias IrxGrantJudgment =
    @Sendable (_ grantJWS: String?, _ remoteEndpointIDHex: String) throws -> IrxAdmittedPeerInfo

public struct IrxAdmission: Sendable {
    public init() {}

    /// Admission must resolve fast or fail loud; nothing here touches the
    /// network beyond the connection itself.
    public let deadline: Duration = .seconds(5)

    /// Client half: open the control lane, send the hello (grantless in
    /// list-auth mode; the optional grant exists only for legacy dialects),
    /// await the admit. A denial arrives as the connection's own termination
    /// and is rethrown with its parsed code.
    ///
    /// `authorizesDirectPaths` owns the client side of the NAT barrier: the
    /// hello offers the capability, and after the admit the client authorizes
    /// NAT traversal itself, then (when the server acked) signals
    /// ``IrxClientReady``. The server holds its own authorization, and with
    /// it its ADD_ADDRESS candidate advertisement, until that signal, because
    /// candidates that reach a not-yet-authorized peer are discarded and
    /// tombstoned by the transport with no retransmission (the frames were
    /// ACKed), which strands the connection on relay permanently.
    /// `preAuthorization` runs after the admit and before NAT traversal is
    /// authorized: callers put their post-admit validity rechecks (dial
    /// scope, binding identity) here so a stale dial can never start
    /// exchanging direct candidates. A throw aborts admission before any
    /// candidate disclosure; the caller closes the connection as usual.
    public func performClient(
        connection: IrxConnection,
        grantJWS: String? = nil,
        journal: IrxJournal,
        authorizesDirectPaths: Bool = false,
        preAuthorization: (@Sendable () async throws -> Void)? = nil
    ) async throws -> (IrxAdmit, IrxLaneStream) {
        do {
            return try await clientExchange(
                connection: connection, grantJWS: grantJWS, journal: journal,
                authorizesDirectPaths: authorizesDirectPaths,
                preAuthorization: preAuthorization)
        } catch let denial as IrxAdmissionDenied {
            throw denial
        } catch {
            try Task.checkCancellation()
            // A remote denial can terminate any native open/write/read stage,
            // not just yield EOF from the admit reader. Inspect the already
            // published close reason without waiting for a second deadline.
            if let reason = await connection.closeReason(),
               let code = IrxCloseCode.parse(fromRenderedCause: reason),
               code == .admissionTimeout || IrxCloseCode.terminalForAutoRedial.contains(code) {
                journal.record("admission", "denied", ["code": code.rawValue])
                throw IrxAdmissionDenied(code: code)
            }
            throw error
        }
    }

    private func clientExchange(
        connection: IrxConnection,
        grantJWS: String?,
        journal: IrxJournal,
        authorizesDirectPaths: Bool,
        preAuthorization: (@Sendable () async throws -> Void)?
    ) async throws -> (IrxAdmit, IrxLaneStream) {
        let startedAt = DispatchTime.now()
        let control = try await connection.openLane(IrxLaneDescriptor(lane: .control))
        try await control.writer.writeControlFrame(
            IrxHello(grant: grantJWS, natBarrier: authorizesDirectPaths ? true : nil))
        let admit: IrxAdmit?
        do {
            admit = try await withIrxDeadline(deadline, onTimeout: {
                await connection.close(code: .admissionTimeout, origin: .transport)
            }) {
                guard let admit = try await control.reader.readControlFrame(IrxAdmit.self) else {
                    throw IrxConnectionError.closed(await connection.termination())
                }
                return admit
            }
        } catch {
            // A peer denial can surface as a native QUIC read error before
            // the stream wrapper returns EOF. Preserve its machine-readable
            // connection reason for the admission caller.
            if await connection.isConnectionClosed() {
                let termination = await connection.termination()
                journal.record(
                    "admission", "denied-or-timeout",
                    ["code": termination.code]
                )
                if let code = IrxCloseCode(rawValue: termination.code),
                    IrxCloseCode.admissionOutcomeCodes.contains(code)
                {
                    throw IrxAdmissionDenied(code: code)
                }
                throw IrxConnectionError.closed(termination)
            }
            throw error
        }
        guard let admit else {
            // A stalled QUIC read can outlive the deadline and ignore task
            // cancellation. Preserve a close reason already received from the
            // peer; otherwise close locally so the read loses its transport
            // owner before we inspect the termination reason.
            if await connection.closeReason() == nil {
                await connection.close(code: .admissionTimeout, origin: .transport)
            }
            let termination = await connection.termination()
            journal.record(
                "admission", "denied-or-timeout",
                ["code": termination.code]
            )
            if let code = IrxCloseCode(rawValue: termination.code),
                IrxCloseCode.admissionOutcomeCodes.contains(code)
            {
                throw IrxAdmissionDenied(code: code)
            }
            throw IrxConnectionError.closed(termination)
        }
        let elapsedMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        journal.record(
            "admission", "admitted",
            [
                "session": admit.session,
                "elapsed_ms": String(elapsedMs),
                "path": connection.selectedPathDescription(),
            ]
        )
        if authorizesDirectPaths {
            // The caller's post-admit validity recheck runs before any
            // authorization, so a dial that went stale during admission
            // never discloses direct candidates. On an acked barrier the
            // resulting abort skips ready, and the server times the wait
            // out into a reasoned admission-timeout close.
            try await preAuthorization?()
            // Client-first ordering: authorize before signaling the server,
            // so the server's candidate advertisement can only reach an
            // already-authorized client. authorizeDirectPaths never throws;
            // a failed authorization is journaled and ready is still sent so
            // a barrier server cannot deadlock waiting on it.
            await connection.authorizeDirectPaths()
            if admit.natBarrier == true {
                try await control.writer.writeControlFrame(IrxClientReady())
                journal.record("admission", "nat-barrier", ["state": "client-ready-sent"])
            } else {
                journal.record("admission", "nat-barrier", ["state": "legacy-server"])
            }
        }
        return (admit, control)
    }

    /// Server half: read the control descriptor + hello off the first stream,
    /// judge the grant against the TLS key, admit or terminate with the
    /// denial code. On success the remote's lane credit is raised and the
    /// admit frame commits the session.
    public func performServer(
        connection: IrxConnection,
        judgment: IrxGrantJudgment,
        journal: IrxJournal
    ) async -> (IrxAdmittedPeerInfo, IrxLaneStream, String)? {
        do {
            let controlResult = try await withIrxDeadlineResult(deadline) {
                await connection.acceptLane()
            }
            let control: IrxLaneStream?
            switch controlResult {
            case .operation(let value):
                control = value
            case .timeout:
                await connection.close(code: .admissionTimeout, origin: .local)
                return nil
            }
            guard let control, control.descriptor.lane == .control else {
                journal.record("admission", "rejected", ["code": IrxCloseCode.malformedHello.rawValue])
                await connection.close(code: .malformedHello, origin: .local)
                return nil
            }
            let helloResult = try await withIrxDeadlineResult(deadline) {
                try await control.reader.readControlFrame(IrxHello.self)
            }
            let hello: IrxHello?
            switch helloResult {
            case .operation(let value):
                hello = value
            case .timeout:
                await connection.close(code: .admissionTimeout, origin: .local)
                return nil
            }
            guard let hello, hello.proto == IrxProtocol().alpn else {
                journal.record("admission", "rejected", ["code": IrxCloseCode.protocolMismatch.rawValue])
                await connection.close(code: .protocolMismatch, origin: .local)
                return nil
            }
            let peer: IrxAdmittedPeerInfo
            do {
                peer = try judgment(hello.grant, connection.remoteEndpointIDHex)
            } catch let denial as IrxAdmissionDenied {
                journal.record(
                    "admission", "denied",
                    [
                        "code": denial.code.rawValue,
                        "remote": String(connection.remoteEndpointIDHex.prefix(12)),
                    ]
                )
                await connection.close(code: denial.code, origin: .local)
                return nil
            } catch {
                journal.record(
                    "admission", "denied",
                    ["code": IrxCloseCode.invalidGrant.rawValue, "error": String(describing: error)]
                )
                await connection.close(code: .invalidGrant, origin: .local)
                return nil
            }
            let sessionID = UUID().uuidString.lowercased()
            // Lanes: keepalive + terminals + artifact + headroom. Uni stays 0
            // (the client never opens unidirectional streams).
            await connection.raiseRemoteStreamCredit(bi: 64, uni: 0)
            let barrier = hello.natBarrier == true
            try await control.writer.writeControlFrame(
                IrxAdmit(session: sessionID, natBarrier: barrier ? true : nil))
            if barrier {
                // Hold admission open until the client proves it authorized
                // NAT traversal, so this side's authorization (and with it
                // the ADD_ADDRESS candidate advertisement) can never beat the
                // client's own authorization onto the wire.
                let readyResult = try await withIrxDeadlineResult(deadline) {
                    try await control.reader.readControlFrame(IrxClientReady.self)
                }
                switch readyResult {
                case .operation(.some):
                    journal.record(
                        "admission", "nat-barrier", ["state": "client-ready-received"])
                case .operation(.none), .timeout:
                    journal.record(
                        "admission", "nat-barrier", ["state": "client-ready-missing"])
                    await connection.close(code: .admissionTimeout, origin: .local)
                    return nil
                }
            }
            journal.record(
                "admission", "admitted",
                [
                    "session": sessionID,
                    "device": peer.deviceID,
                    "binding": peer.bindingID,
                    "path": connection.selectedPathDescription(),
                ]
            )
            return (peer, control, sessionID)
        } catch {
            journal.record(
                "admission", "failed",
                ["error": String(describing: error)]
            )
            await connection.close(code: .admissionTimeout, origin: .local)
            return nil
        }
    }
}
