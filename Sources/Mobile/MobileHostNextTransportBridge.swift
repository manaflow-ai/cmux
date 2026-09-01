#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import CmuxNextTransportBridge
import CryptoKit
import Foundation
import OSLog

/// Graduation lane routing (P4 router slice): every admitted next-transport
/// connection gets the SAME application service as an old-transport one —
/// the control RPC service, the application lane router, and the server
/// event writer — assembled over bridged raw streams. Features, quotas, and
/// lifecycle ownership are the legacy code paths, unchanged.
enum MobileHostNextTransportBridge {
    private static func hex(_ bytes: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The admitted-peer tuple downstream authorization keys on, minted from
    /// the verified next-transport grant plus the QUIC-authenticated key.
    static func synthesizedPeer(
        grant: PairingGrant, deviceKey: Data
    ) -> CmxIrohAdmittedPeer? {
        let hex = Self.hex(deviceKey)
        guard let endpointID = try? CmxIrohPeerIdentity(endpointID: hex) else { return nil }
        // A grant is short-lived and rotates on every reconnect; binding
        // ownership to its ID would let the same device accumulate parallel
        // legacy sessions. Derive the adapter binding from stable account,
        // device, and app identity instead.
        let stableIdentity = Data(
            "\(grant.accountID)\u{0}\(grant.deviceID)\u{0}\(grant.appIdentity)".utf8)
        let bindingDigest = SHA256.hash(data: stableIdentity)
        return CmxIrohAdmittedPeer(
            peer: CmxIrohGrantPeer(
                bindingID: "next:\(Self.hex(Data(bindingDigest)))",
                deviceID: grant.deviceID,
                tag: grant.appIdentity,
                platform: .ios,
                endpointID: endpointID,
                identityGeneration: 1))
    }

    /// Serves one admitted connection until it closes. Mirrors the legacy
    /// handleTransport assembly: supervisor owns the lifetime, control exit
    /// closes the connection and joins the lanes.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func run(
        connection: IrohPeerConnection,
        grant: PairingGrant,
        deviceKey: Data,
        isCurrent: @escaping @Sendable () async -> Bool
    ) async {
        let bridgeStart = ContinuousClock.now
        let connID = String(UInt(bitPattern: ObjectIdentifier(connection).hashValue) & 0xFFFF_FFFF, radix: 16)
        let devicePrefix = String(grant.deviceID.prefix(8))
        MobileHostNextTransportRuntime.logger.notice(
            """
            bridge assembly begin conn=\(connID, privacy: .public) \
            device=\(devicePrefix, privacy: .private) \
            app=\(grant.appIdentity, privacy: .public) \
            grantID=\(String(grant.grantID.prefix(8)), privacy: .private)
            """)
        guard let peer = synthesizedPeer(grant: grant, deviceKey: deviceKey) else {
            MobileHostNextTransportRuntime.logger.error(
                """
                bridge: unusable device key; closing conn=\(connID, privacy: .public) \
                device=\(devicePrefix, privacy: .private) \
                key=\(Self.hex(Data(deviceKey.prefix(4))), privacy: .public)
                """)
            await connection.closeAll(reason: nil)
            return
        }
        let acceptor = await BridgeLaneAcceptor.attached(to: connection)
        MobileHostNextTransportRuntime.logger.notice(
            "bridge: lane acceptor attached conn=\(connID, privacy: .public)")
        let routable = NextTransportRoutableSession(peer: peer, acceptor: acceptor)
        let eventWriter = MobileHostIrohServerEventWriter(
            openStream: {
                try await BridgeLaneDialer.openServerEventSendStream(
                    on: connection, priority: 50)
            },
            clock: CmxIrohSystemRelayClock(),
            sendTimeout: 3)
        // Open the host-owned event stream as soon as the admitted bridge is
        // assembled. The phone's optional-event negotiation waits for this
        // host-opened stream before it can advertise `iroh_server_events_v1`;
        // deferring the first open until after that advertisement would make
        // both sides wait on one another.
        let eventPreparationTask = Task {
            try? await eventWriter.prepare()
        }
        let artifactTransfers = MobileHostIrohArtifactTransferRegistry()
        let laneRouter = MobileHostIrohApplicationLaneRouter(
            session: routable,
            artifactHandler: MobileHostIrohArtifactLaneHandler(registry: artifactTransfers),
            simulatorStreamHandler: MobileHostIrohSimulatorStreamLaneHandler())
        MobileHostNextTransportRuntime.logger.notice(
            """
            bridge: event writer + lane router assembled conn=\(connID, privacy: .public) \
            device=\(devicePrefix, privacy: .private)
            """)
        let supervisor = CmxIrohAdmittedConnectionSupervisor(
            runControl: {
                guard let control = try? await acceptor.nextControlStream() else {
                    MobileHostNextTransportRuntime.logger.notice(
                        """
                        bridge: control stream never arrived (connection closed) \
                        conn=\(connID, privacy: .public) \
                        device=\(devicePrefix, privacy: .private)
                        """)
                    return CmxIrohAdmittedConnectionExit(
                        lifecycle: .remoteClosed, failure: .none)
                }
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    bridge: control stream accepted; starting RPC service \
                    conn=\(connID, privacy: .public) \
                    device=\(devicePrefix, privacy: .private)
                    """)
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
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    bridge: supervisor closing connection conn=\(connID, privacy: .public) \
                    device=\(devicePrefix, privacy: .private)
                    """)
                await connection.closeAll(reason: nil)
            },
            stopApplicationLanes: {
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    bridge: stopping application lanes conn=\(connID, privacy: .public) \
                    device=\(devicePrefix, privacy: .private)
                """)
                eventPreparationTask.cancel()
                await eventWriter.close()
                await laneRouter.stop()
                await acceptor.finish()
            })
        MobileHostNextTransportRuntime.logger.notice(
            """
            bridge: serving device \(devicePrefix, privacy: .private) over next transport \
            conn=\(connID, privacy: .public); supervisor starting
            """)
        let exit = await supervisor.run()
        MobileHostNextTransportRuntime.logger.notice(
            """
            bridge: session ended conn=\(connID, privacy: .public) \
            device=\(devicePrefix, privacy: .private) \
            lifecycle=\(exit.lifecycle.rawValue, privacy: .public) \
            failure=\(String(describing: exit.failure), privacy: .public) \
            elapsedMs=\(MobileHostNextTransportRuntime.elapsedMs(since: bridgeStart), privacy: .public)
            """)
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
