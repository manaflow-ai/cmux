import Foundation
import CmuxAttach

/// The host-side operations a `SurfaceAttachSession` needs from the running app,
/// expressed as a narrow seam so the session's framing/lifecycle logic stays
/// independent of `TerminalController` / `GhosttyTerminalView` internals (and so
/// it can be exercised with a fake bridge in tests). The concrete adapter that
/// wires these to real surfaces lives in `TerminalController`.
@MainActor
protocol SurfaceAttachBridge: AnyObject {
    /// Resolve a surface reference (UUID or short ref) to a stable surface id,
    /// or return nil if it is not an attachable terminal surface.
    func resolveTerminalSurface(reference: String) -> UUID?
    /// Bounded scrollback tail and its sequence for a cold attach, if any.
    func replayState(surfaceID: UUID) -> (seq: UInt64, data: Data)?
    /// Register for live raw bytes; returns a token for `unsubscribe`.
    func subscribe(surfaceID: UUID, _ onBytes: @escaping @MainActor (Data) -> Void) -> Int
    func unsubscribe(surfaceID: UUID, token: Int)
    /// Feed raw stdin bytes to the surface's PTY (no-op when read-only).
    func writeInput(surfaceID: UUID, bytes: Data)
    /// Apply this client's size to the surface (min-arbitrated with the GUI).
    func applyAttachmentSize(surfaceID: UUID, size: SurfaceSize)
    /// Drop this client's size contribution, restoring the GUI's own size.
    func clearAttachmentSize(surfaceID: UUID)
    /// Nudge the surface to repaint a clean frame after a raw-tail replay so a
    /// full-screen TUI is not left rendering from a mid-escape-sequence tail.
    func requestRedraw(surfaceID: UUID)
}

/// Owns one bare-terminal attachment to a GUI surface over the control socket.
///
/// Wire shape mirrors `events.stream`: this runs after `handleClient` hands off
/// the connection, so the session owns the socket. Output is pushed as the tee
/// delivers bytes; inbound stdin/resize/detach frames are read concurrently on a
/// dedicated reader thread (the gap the push-only `events.stream` loop does not
/// cover). On any teardown the surface keeps running - detach never signals the
/// pane process.
///
/// Concurrency: all socket writes and bridge calls happen on the main actor, so
/// they are serialized without a lock; the reader thread only reads bytes and
/// hops decoded frames to the main actor.
@MainActor
final class SurfaceAttachSession {
    private let socket: Int32
    private let request: AttachRequest
    private let bridge: SurfaceAttachBridge
    private let write: @Sendable (Data) -> Bool

    private var surfaceID: UUID?
    private var subscriptionToken: Int?
    private var torndown = false
    /// Running byte offset of the live stream, used as the `seq` on output
    /// frames so the client can detect drops. Seeded from the replay sequence.
    private var liveSeq: UInt64 = 0

    /// - Parameter write: writes all bytes to the socket, returning false if the
    ///   peer is gone. Injected so the session does not bind to a transport type.
    init(
        socket: Int32,
        request: AttachRequest,
        bridge: SurfaceAttachBridge,
        write: @escaping @Sendable (Data) -> Bool
    ) {
        self.socket = socket
        self.request = request
        self.bridge = bridge
        self.write = write
    }

    /// Resolve the surface, send ack + replay, start the live stream and the
    /// inbound reader. Returns after the attachment is wired; the reader thread
    /// keeps the connection alive until detach/EOF.
    func start() {
        guard let surfaceID = bridge.resolveTerminalSurface(reference: request.surface) else {
            _ = write(AttachFrame.error(code: "surface_not_found", message: "no attachable terminal surface for \(request.surface)").encodedLine())
            return
        }
        self.surfaceID = surfaceID

        let replay = bridge.replayState(surfaceID: surfaceID)
        let startSeq = replay?.seq ?? 0
        liveSeq = startSeq
        guard write(AttachFrame.ack(seq: startSeq).encodedLine()) else { return }
        if let replay, !replay.data.isEmpty {
            // The replay's sequence is the END of the tail; emit it as the chunk
            // that lands the client at startSeq.
            let replayStart = startSeq >= UInt64(replay.data.count) ? startSeq - UInt64(replay.data.count) : 0
            guard write(AttachFrame.output(seq: replayStart, bytes: replay.data).encodedLine()) else { return }
        }

        bridge.applyAttachmentSize(surfaceID: surfaceID, size: request.size)
        // Clean repaint after a raw-tail replay (KTD7).
        bridge.requestRedraw(surfaceID: surfaceID)

        subscriptionToken = bridge.subscribe(surfaceID: surfaceID) { [weak self] data in
            guard let self else { return }
            let frame = AttachFrame.output(seq: self.liveSeq, bytes: data)
            self.liveSeq &+= UInt64(data.count)
            if !self.write(frame.encodedLine()) {
                self.teardown()
            }
        }

        startReader(surfaceID: surfaceID)
    }

    /// Read inbound frames on a dedicated thread and deliver them, in order,
    /// through an `AsyncStream` to a single main-actor consumer. The stream
    /// preserves order (which a `Task`-per-frame hop would not), so stdin bytes
    /// reach the PTY in the sequence the client sent them. Blocking reads belong
    /// off the cooperative pool, hence a `Thread` for the producer.
    private func startReader(surfaceID: UUID) {
        let fd = socket
        let (stream, continuation) = AsyncStream.makeStream(of: AttachFrame.self)

        let thread = Thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex...newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if let frame = try? AttachFrame(line: Data(line)) {
                        continuation.yield(frame)
                    }
                }
            }
            continuation.finish()
        }
        thread.name = "dev.cmux.surface-attach.reader"
        thread.start()

        Task { @MainActor [weak self] in
            for await frame in stream {
                guard let self else { break }
                self.handle(frame, surfaceID: surfaceID)
            }
            self?.teardown()
        }
    }

    private func handle(_ frame: AttachFrame, surfaceID: UUID) {
        switch frame {
        case .input(let bytes):
            if !request.readOnly { bridge.writeInput(surfaceID: surfaceID, bytes: bytes) }
        case .resize(let cols, let rows):
            bridge.applyAttachmentSize(surfaceID: surfaceID, size: SurfaceSize(cols: cols, rows: rows))
        case .detach:
            teardown()
        default:
            break // clients do not send ack/output/heartbeat
        }
    }

    private func teardown() {
        guard !torndown else { return }
        torndown = true
        if let surfaceID, let token = subscriptionToken {
            bridge.unsubscribe(surfaceID: surfaceID, token: token)
        }
        if let surfaceID {
            bridge.clearAttachmentSize(surfaceID: surfaceID)
        }
        // The pane process is intentionally left running.
    }
}
