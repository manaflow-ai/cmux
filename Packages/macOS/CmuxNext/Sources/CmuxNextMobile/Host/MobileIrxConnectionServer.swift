import CMUXMobileCore
import CmuxIrxTransport
import Foundation

/// Serves one admitted phone connection: the control stream speaks the
/// shipped mobile RPC dialect (compat adapter), and feature lanes carry
/// keepalives, control-stream repair, and daemon-lane splices.
struct MobileIrxConnectionServer: Sendable {
    let connection: IrxConnection
    let control: IrxLaneStream
    let deviceID: String
    let makeSession: @Sendable (_ emit: @escaping MobileCompatSession.Emit) -> MobileCompatSession
    let daemonSocketPath: @Sendable () async -> String?
    let journal: IrxJournal

    /// Runs until the phone disconnects or the host closes the connection.
    func run() async {
        let transport = IrxControlByteTransport(connection: connection, control: control, closeCode: .hostShutdown)
        let session = makeSession { json in
            guard let frame = try? MobileSyncFrameCodec.encodeFrame(json) else { return }
            try? await transport.send(frame)
        }
        let lanes = Task { await serveLanes(transport: transport) }
        await serveControl(transport: transport, session: session)
        lanes.cancel()
        await session.close()
        await transport.close()
    }

    private func serveControl(transport: IrxControlByteTransport, session: MobileCompatSession) async {
        var buffer = Data()
        do {
            while let chunk = try await transport.receive() {
                buffer.append(chunk)
                var frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
                while !frames.isEmpty {
                    for frame in frames {
                        // Requests run in arrival order: input stays ordered.
                        let response = await session.handle(frame: frame)
                        try await transport.send(MobileSyncFrameCodec.encodeFrame(response))
                    }
                    frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
                }
            }
        } catch {
            journal.record("next-host", "control-ended", ["error": String(describing: type(of: error))])
        }
    }

    private func serveLanes(transport: IrxControlByteTransport) async {
        // wakeup-allow: awaits the next lane; ends when the connection closes (nil)
        while !Task.isCancelled, let lane = await connection.acceptLane() {
            switch lane.descriptor.lane {
            case .keepalive:
                _ = connection.respondKeepalive(on: lane)
            case .controlRepair:
                // task-owner: bound to this phone connection; ends when its transport closes
                Task { _ = await transport.acceptControlLaneReplacement(lane) }
            case .daemon:
                // task-owner: bound to this lane; the splice ends when either side closes
                Task { await splice(lane) }
            default:
                // Terminal, artifact, simulator and tunnel lanes belong to
                // features this Mac does not advertise.
                await lane.writer.reset(errorCode: 2)
                await lane.reader.stop(errorCode: 2)
            }
        }
    }

    private func splice(_ lane: IrxLaneStream) async {
        let machine = lane.descriptor.resource ?? "local"
        guard machine == "local", let path = await daemonSocketPath(),
              let daemon = try? await UnixSocketLane.connect(path: path) else {
            journal.record("next-host", "daemon-lane-refused", ["machine": machine])
            await lane.writer.reset(errorCode: 2)
            await lane.reader.stop(errorCode: 2)
            return
        }
        journal.record("next-host", "daemon-lane-open", ["machine": machine])
        let splice = DaemonLaneSplice(phone: IrxByteLane(lane: lane), daemon: daemon,
                                      policy: DaemonLanePolicy(deviceID: deviceID))
        let reason = await splice.run()
        journal.record("next-host", "daemon-lane-closed", ["reason": String(describing: reason)])
    }
}
