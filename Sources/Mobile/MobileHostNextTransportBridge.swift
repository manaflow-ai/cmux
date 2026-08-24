#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog

/// Graduation lane routing (P4 router slice): every admitted next-transport
/// connection gets the SAME application service as an old-transport one —
/// the control RPC service, the application lane router, and the server
/// event writer — assembled over bridged raw streams. Features, quotas, and
/// lifecycle ownership are the legacy code paths, unchanged.
enum MobileHostNextTransportBridge {
    /// The admitted-peer tuple downstream authorization keys on, minted from
    /// the verified next-transport grant plus the QUIC-authenticated key.
    static func synthesizedPeer(
        grant: PairingGrant, deviceKey: Data
    ) -> CmxIrohAdmittedPeer? {
        let hex = deviceKey.map { String(format: "%02x", $0) }.joined()
        guard let endpointID = try? CmxIrohPeerIdentity(endpointID: hex) else { return nil }
        return CmxIrohAdmittedPeer(
            peer: CmxIrohGrantPeer(
                bindingID: "next:\(grant.grantID)",
                deviceID: grant.deviceID,
                tag: grant.appIdentity,
                platform: .ios,
                endpointID: endpointID,
                identityGeneration: 1))
    }

    /// Serves one admitted connection until it closes. Mirrors the legacy
    /// handleTransport assembly: supervisor owns the lifetime, control exit
    /// closes the connection and joins the lanes.
    static func run(
        connection: IrohPeerConnection,
        grant: PairingGrant,
        deviceKey: Data
    ) async {
        guard let peer = synthesizedPeer(grant: grant, deviceKey: deviceKey) else {
            mobileHostNextTransportLog.error("bridge: unusable device key; closing")
            await connection.closeAll(reason: nil)
            return
        }
        let acceptor = await BridgeLaneAcceptor.attached(to: connection)
        let routable = NextTransportRoutableSession(peer: peer, acceptor: acceptor)
        let eventWriter = MobileHostIrohServerEventWriter(
            openStream: {
                try await BridgeLaneDialer.openServerEventSendStream(
                    on: connection, priority: 50)
            },
            clock: CmxIrohSystemRelayClock(),
            sendTimeout: 3)
        let artifactTransfers = MobileHostIrohArtifactTransferRegistry()
        let laneRouter = MobileHostIrohApplicationLaneRouter(
            session: routable,
            artifactHandler: MobileHostIrohArtifactLaneHandler(registry: artifactTransfers),
            simulatorStreamHandler: MobileHostIrohSimulatorStreamLaneHandler())
        let isCurrent: @Sendable () async -> Bool = {
            let enabled = await MainActor.run {
                MobileHostNextTransportRuntime.shared.isEnabled
            }
            guard enabled else { return false }
            return await !connection.isClosed
        }
        let supervisor = CmxIrohAdmittedConnectionSupervisor(
            runControl: {
                guard let control = try? await acceptor.nextControlStream() else {
                    return CmxIrohAdmittedConnectionExit(
                        lifecycle: .remoteClosed, failure: .none)
                }
                return await MobileHostService.acceptTransport(
                    BridgeByteTransport(stream: control),
                    authorization: .irohAdmission(peer),
                    artifactTransfers: artifactTransfers,
                    independentEventWriter: eventWriter,
                    promoteUsableSession: { true },
                    isCurrent: isCurrent)
            },
            runApplicationLanes: {
                await laneRouter.run(isCurrent: isCurrent)
            },
            closeConnection: {
                await connection.closeAll(reason: nil)
            },
            stopApplicationLanes: {
                await laneRouter.stop()
                await acceptor.finish()
            })
        mobileHostNextTransportLog.info(
            "bridge: serving device \(grant.deviceID, privacy: .public) over next transport")
        let exit = await supervisor.run()
        mobileHostNextTransportLog.info(
            "bridge: session ended lifecycle=\(exit.lifecycle.rawValue, privacy: .public)")
    }
}

/// The router-facing session facade over one bridged connection.
struct NextTransportRoutableSession: MobileHostRoutableLaneSession {
    let peer: CmxIrohAdmittedPeer
    let acceptor: BridgeLaneAcceptor

    func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        try await acceptor.acceptBidirectionalLane()
    }
}
#endif
