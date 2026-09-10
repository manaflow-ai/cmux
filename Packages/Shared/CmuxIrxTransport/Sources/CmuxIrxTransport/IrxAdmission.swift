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

public enum IrxAdmission {
    /// Admission must resolve fast or fail loud; nothing here touches the
    /// network beyond the connection itself.
    public static let deadline: Duration = .seconds(5)

    /// Client half: open the control lane, send the hello (grantless in
    /// list-auth mode; the optional grant exists only for legacy dialects),
    /// await the admit. A denial arrives as the connection's own termination
    /// and is rethrown with its parsed code.
    public static func performClient(
        connection: IrxConnection,
        grantJWS: String? = nil,
        journal: IrxJournal
    ) async throws -> (IrxAdmit, IrxLaneStream) {
        let startedAt = DispatchTime.now()
        let control = try await connection.openLane(IrxLaneDescriptor(lane: .control))
        try await control.writer.writeControlFrame(IrxHello(grant: grantJWS))
        let admit = try await withIrxDeadline(deadline, onTimeout: {
            await connection.close(code: .admissionTimeout, origin: .transport)
        }) {
            guard let admit = try await control.reader.readControlFrame(IrxAdmit.self) else {
                throw IrxConnectionError.closed(await connection.termination())
            }
            return admit
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
            if let code = IrxCloseCode(rawValue: termination.code) {
                throw IrxAdmissionDenied(code: code)
            }
            throw IrxConnectionError.admissionTimeout
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
        return (admit, control)
    }

    /// Server half: read the control descriptor + hello off the first stream,
    /// judge the grant against the TLS key, admit or terminate with the
    /// denial code. On success the remote's lane credit is raised and the
    /// admit frame commits the session.
    public static func performServer(
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
            guard let hello, hello.proto == IrxProtocol.alpn else {
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
            try await control.writer.writeControlFrame(IrxAdmit(session: sessionID))
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
