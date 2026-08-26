#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxPeerTransport
import CmuxPeerTransportBridge
import Foundation
import OSLog

/// Peer transport v2 lane routing: every admitted v2 connection gets the SAME
/// application service as a legacy one — the control RPC service, the
/// application lane router, and the server event writer — assembled over
/// bridged raw streams. Features, quotas, and lifecycle ownership are the
/// legacy code paths, unchanged.
enum MobileHostPtxBridge {
    /// The admitted-peer tuple downstream authorization keys on, minted from
    /// the verified v2 grant plus the QUIC-authenticated remote key.
    static func synthesizedPeer(
        grant: PtxGrant, remoteKey: Data
    ) -> CmxIrohAdmittedPeer? {
        let hex = remoteKey.map { String(format: "%02x", $0) }.joined()
        guard let endpointID = try? CmxIrohPeerIdentity(endpointID: hex) else { return nil }
        return CmxIrohAdmittedPeer(
            peer: CmxIrohGrantPeer(
                bindingID: "ptx:\(grant.grantID)",
                deviceID: grant.deviceID,
                tag: grant.appIdentity,
                platform: .ios,
                endpointID: endpointID,
                identityGeneration: 1
            )
        )
    }

    /// Serves one admitted session until it closes. Mirrors the legacy
    /// handleTransport assembly: the supervisor owns the lifetime, control
    /// exit closes the connection and joins the lanes.
    static func run(session: PtxHostSession) async {
        let connection = session.connection
        let grant = session.grant
        let devicePrefix = String(grant.deviceID.prefix(8))
        mobileHostPtxLog.notice(
            """
            bridge assembly begin session=\(session.sessionID, privacy: .public) \
            device=\(devicePrefix, privacy: .public) \
            app=\(grant.appIdentity, privacy: .public) \
            grantID=\(grant.grantID, privacy: .public)
            """
        )
        guard let peer = synthesizedPeer(grant: grant, remoteKey: session.remoteKey) else {
            mobileHostPtxLog.error(
                """
                bridge: unusable remote key; closing session=\(session.sessionID, privacy: .public) \
                device=\(devicePrefix, privacy: .public) \
                key=\(PtxEventLog.hex8(session.remoteKey), privacy: .public)
                """
            )
            await connection.close(reason: PtxCloseReason.hostStopping.rawValue)
            return
        }
        let acceptor = await PtxBridgeAcceptor.attached(
            to: connection,
            acceptsServerEvents: false
        )
        let routable = PtxRoutableLaneSession(peer: peer, acceptor: acceptor)
        let eventWriter = MobileHostIrohServerEventWriter(
            openStream: {
                try await PtxBridgeDialer.openServerEventSendStream(
                    on: connection,
                    priority: 50
                )
            },
            clock: CmxIrohSystemRelayClock(),
            sendTimeout: 3
        )
        let artifactTransfers = MobileHostIrohArtifactTransferRegistry()
        let laneRouter = MobileHostIrohApplicationLaneRouter(
            session: routable,
            artifactHandler: MobileHostIrohArtifactLaneHandler(registry: artifactTransfers),
            simulatorStreamHandler: MobileHostIrohSimulatorStreamLaneHandler()
        )
        let sessionID = session.sessionID
        let isCurrent: @Sendable () async -> Bool = {
            let enabled = await MainActor.run {
                MobileHostPtxRuntime.shared.isEnabled
            }
            guard enabled else {
                mobileHostPtxLog.notice(
                    """
                    bridge: isCurrent=false (runtime disabled) \
                    session=\(sessionID, privacy: .public)
                    """
                )
                return false
            }
            return await !connection.isClosed
        }
        let supervisor = CmxIrohAdmittedConnectionSupervisor(
            runControl: {
                // A ptx connection OUTLIVES any single RPC client: the phone's
                // reconnect owner holds the session ready while RPC clients
                // come and go, each opening a fresh control stream. Serve
                // every inbound control stream (concurrently: a replacement
                // client's stream can overlap the dying one's during handoff)
                // until the connection itself closes.
                var served = 0
                await withDiscardingTaskGroup { group in
                    while let control = try? await acceptor.nextControlStream() {
                        served += 1
                        let ordinal = served
                        mobileHostPtxLog.notice(
                            """
                            bridge: control stream #\(ordinal, privacy: .public) accepted; \
                            starting RPC service \
                            session=\(sessionID, privacy: .public) \
                            device=\(devicePrefix, privacy: .public)
                            """
                        )
                        group.addTask {
                            _ = await MobileHostService.acceptTransport(
                                PtxBridgeByteTransport(stream: control),
                                authorization: .irohAdmission(peer),
                                artifactTransfers: artifactTransfers,
                                independentEventWriter: eventWriter,
                                promoteUsableSession: { true },
                                isCurrent: isCurrent
                            )
                        }
                    }
                }
                mobileHostPtxLog.notice(
                    """
                    bridge: control accept loop ended (connection closed) \
                    session=\(sessionID, privacy: .public) \
                    device=\(devicePrefix, privacy: .public) \
                    served=\(served, privacy: .public)
                    """
                )
                return CmxIrohAdmittedConnectionExit(
                    lifecycle: .remoteClosed,
                    failure: .none
                )
            },
            runApplicationLanes: {
                await laneRouter.run(isCurrent: isCurrent)
            },
            closeConnection: {
                mobileHostPtxLog.notice(
                    """
                    bridge: supervisor closing connection \
                    session=\(sessionID, privacy: .public) \
                    device=\(devicePrefix, privacy: .public)
                    """
                )
                await connection.close(reason: PtxCloseReason.hostStopping.rawValue)
            },
            stopApplicationLanes: {
                await laneRouter.stop()
                await acceptor.finish()
            }
        )
        mobileHostPtxLog.notice(
            """
            bridge: serving device \(grant.deviceID, privacy: .public) over peer \
            transport v2 session=\(sessionID, privacy: .public); supervisor starting
            """
        )
        let exit = await supervisor.run()
        mobileHostPtxLog.notice(
            """
            bridge: session ended session=\(sessionID, privacy: .public) \
            device=\(devicePrefix, privacy: .public) \
            lifecycle=\(exit.lifecycle.rawValue, privacy: .public) \
            failure=\(String(describing: exit.failure), privacy: .public)
            """
        )
    }
}

/// The router-facing session facade over one bridged v2 connection.
struct PtxRoutableLaneSession: MobileHostRoutableLaneSession {
    let peer: CmxIrohAdmittedPeer
    let acceptor: PtxBridgeAcceptor

    func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        try await acceptor.acceptBidirectionalLane()
    }
}
#endif
