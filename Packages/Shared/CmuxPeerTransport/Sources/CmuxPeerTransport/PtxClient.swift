import Foundation
import IrohLib

/// The client-side connect flow: one dial + single-phase admission. Returns
/// `.denied` only for reason codes the host deliberately closed with; every
/// other failure is transient and throws.
public enum PtxClient {
    public struct DialPlan: Sendable {
        public var ticket: PtxTicket
        /// Soak/dev mode: strips direct addresses so every byte crosses the
        /// relay. Also how the simulator (normally loopback-routed) exercises
        /// the real relay path.
        public var relayOnly: Bool

        public init(ticket: PtxTicket, relayOnly: Bool) {
            self.ticket = ticket
            self.relayOnly = relayOnly
        }
    }

    public static func connect(
        endpoint: Endpoint, plan: DialPlan, identity: PtxIdentity, grant: PtxGrant,
        log: PtxEventLog
    ) async throws -> PtxDialOutcome {
        let ticket = plan.ticket
        let addr = try PtxEndpoint.addr(
            id: ticket.hostEndpointKey,
            relayURL: ticket.relayURL,
            directAddresses: plan.relayOnly ? [] : ticket.directAddresses)
        let start = ContinuousClock.now
        let connection = try await PtxEndpoint.dial(endpoint: endpoint, to: addr, log: log)
        let control = try await connection.openControlLane()
        try await control.sendFrame(
            PtxFrame(
                type: PtxFrameType.hello,
                payload: [
                    "protocol": .string(PtxProtocol.identifier),
                    "device_id": .string(identity.deviceID),
                    "app": .string(identity.appIdentity),
                    "key": .data(identity.publicKeyData),
                    "grant": grant.payloadValue,
                ]))
        guard let reply = await control.receiveFrame() else {
            // The host closed instead of admitting: the reason rides the
            // connection termination, the single denial channel.
            let cause = await connection.termination()
            if let cause, cause.hasPrefix("denied-") {
                return .denied(cause)
            }
            throw PtxTransportError.admissionFailed(cause ?? "closed-before-admit")
        }
        guard reply.type == PtxFrameType.admit,
            let sessionID = reply.payload["session"]?.stringValue
        else {
            await connection.close(reason: PtxDenial.protocolMismatch.rawValue)
            throw PtxTransportError.admissionFailed("unexpected-admit-frame:\(reply.type)")
        }
        log.emit(
            PtxEventKind.sessionReady, peer: ticket.hostEndpointKey, session: sessionID,
            ms: log.elapsedMs(since: start),
            detail: ["relayOnly": plan.relayOnly ? "1" : "0"])
        return .admitted(
            PtxClientSession(sessionID: sessionID, connection: connection, control: control))
    }
}
