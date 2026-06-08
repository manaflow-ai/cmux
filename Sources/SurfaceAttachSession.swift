import Foundation
import CmuxAttach

/// The host-side operations a `SurfaceAttachSession` needs from the running app,
/// expressed as a narrow seam so the session's framing/lifecycle logic stays
/// independent of `TerminalSurface` / registry internals (and so it can be
/// exercised with a fake bridge in tests). The concrete adapter is
/// `TerminalSurfaceAttachBridge` below.
@MainActor
protocol SurfaceAttachBridge: AnyObject {
    /// Resolve a surface reference (UUID string) to a stable surface id, or nil
    /// if it is not an attachable terminal surface.
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
/// `handleClient` owns the socket fd and closes it after `handleSurfaceAttachRequest`
/// returns, so this session never closes the fd - on teardown it `shutdown`s the
/// read side to unblock its reader and signals completion. Output is pushed as
/// the byte tee delivers bytes (on the main actor); inbound stdin/resize/detach
/// frames are read on a dedicated thread and delivered in order through an
/// `AsyncStream` to a single main-actor consumer. Detach never signals the pane
/// process - the surface keeps running.
@MainActor
final class SurfaceAttachSession {
    /// Hard cap on a single inbound (client -> host) wire line. Inbound frames
    /// are keystrokes/resize/detach, all small; this only bounds a hostile
    /// newline-free stream.
    private static let maxInboundLineBytes = 1 << 20 // 1 MiB

    private let socket: Int32
    private let request: AttachRequest
    private let bridge: SurfaceAttachBridge
    private let write: @Sendable (Data) -> Bool
    private let onComplete: (@Sendable () -> Void)?

    private var surfaceID: UUID?
    private var subscriptionToken: Int?
    private var torndown = false
    /// Strong self-reference held for the connection's lifetime. The session
    /// outlives `start()` (its reader thread and consumer task run async), and
    /// nothing else retains it, so it retains itself until teardown.
    private var selfRetain: SurfaceAttachSession?
    /// Running byte offset of the live stream, used as the `seq` on output
    /// frames so the client can detect drops. Seeded from the replay sequence.
    private var liveSeq: UInt64 = 0

    init(
        socket: Int32,
        request: AttachRequest,
        bridge: SurfaceAttachBridge,
        write: @escaping @Sendable (Data) -> Bool,
        onComplete: (@Sendable () -> Void)? = nil
    ) {
        self.socket = socket
        self.request = request
        self.bridge = bridge
        self.write = write
        self.onComplete = onComplete
    }

    /// Resolve the surface, send ack + replay, start the live stream and the
    /// inbound reader. Every early exit routes through `teardown()` so the
    /// completion signal always fires.
    func start() {
        selfRetain = self
        guard let surfaceID = bridge.resolveTerminalSurface(reference: request.surface) else {
            _ = write(AttachFrame.error(code: "surface_not_found", message: "no attachable terminal surface for \(request.surface)").encodedLine())
            teardown()
            return
        }
        self.surfaceID = surfaceID

        let replay = bridge.replayState(surfaceID: surfaceID)
        let startSeq = replay?.seq ?? 0
        liveSeq = startSeq
        guard write(AttachFrame.ack(seq: startSeq).encodedLine()) else { teardown(); return }
        if let replay, !replay.data.isEmpty {
            // The replay's sequence is the END of the tail; emit it as the chunk
            // that lands the client at startSeq.
            let replayStart = startSeq >= UInt64(replay.data.count) ? startSeq - UInt64(replay.data.count) : 0
            guard write(AttachFrame.output(seq: replayStart, bytes: replay.data).encodedLine()) else { teardown(); return }
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

    private func startReader(surfaceID: UUID) {
        let fd = socket
        let maxLine = Self.maxInboundLineBytes
        let (stream, continuation) = AsyncStream.makeStream(of: AttachFrame.self)

        let thread = Thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                // Inbound frames are tiny; a newline-free stream must not grow
                // this buffer without bound and OOM the host.
                if pending.count > maxLine { break }
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
        // Once torn down, the session is inert: drop further inbound frames so
        // post-detach input can never reach the PTY and a late resize cannot
        // re-apply a cleared size.
        guard !torndown else { return }
        switch frame {
        case .input(let bytes):
            if !request.readOnly { bridge.writeInput(surfaceID: surfaceID, bytes: bytes) }
        case .resize(let cols, let rows):
            // Mid-session resize takes the same bounds the handshake enforces.
            guard cols >= 1, cols <= AttachHandshake.maxDimension,
                  rows >= 1, rows <= AttachHandshake.maxDimension else { break }
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
        // Shut the socket down (not close - handleClient owns the fd) so the
        // blocked reader thread's read() returns and the thread exits. Then
        // signal the connection thread so handleClient can close and return.
        shutdown(socket, SHUT_RDWR)
        onComplete?()
        selfRetain = nil
    }
}

/// Raw socket writes for attach framing, independent of TerminalController's
/// file-private socket helpers.
enum SurfaceAttachSocketIO {
    /// Write all of `data` to `fd`, returning false if the peer is gone.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var ptr = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { return false }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
            return true
        }
    }
}

extension TerminalController {
    /// Whether a v2 line is a `surface.attach_pty` request (the long-lived
    /// bare-terminal attach), detected the same way as `events.stream`.
    nonisolated func isSurfaceAttachRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        return method == "surface.attach_pty"
    }

    /// Run a bare-terminal attach for the lifetime of the connection. Builds the
    /// session on the main actor (it touches main-actor surface state) and blocks
    /// this connection thread until the session completes, so handleClient's
    /// deferred close() does not pull the fd out from under the session - the
    /// same way `handleEventsStreamRequest` occupies its thread for the stream's
    /// lifetime.
    nonisolated func handleSurfaceAttachRequest(_ line: String, socket: Int32) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any] else {
            _ = SurfaceAttachSocketIO.writeAll(socket, AttachFrame.error(code: "invalid_params", message: "malformed attach request").encodedLine())
            return
        }
        let request: AttachRequest
        do {
            request = try AttachHandshake.parse(params: params)
        } catch {
            _ = SurfaceAttachSocketIO.writeAll(socket, AttachFrame.error(code: "invalid_params", message: String(describing: error)).encodedLine())
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let writeClosure: @Sendable (Data) -> Bool = { SurfaceAttachSocketIO.writeAll(socket, $0) }
        DispatchQueue.main.async {
            let session = SurfaceAttachSession(
                socket: socket,
                request: request,
                bridge: TerminalSurfaceAttachBridge(),
                write: writeClosure,
                onComplete: { semaphore.signal() }
            )
            session.start()
        }
        semaphore.wait()
    }
}

/// Concrete `SurfaceAttachBridge` backed by the app's shared registries: the
/// `TerminalSurfaceRegistry` for surface lookup/I/O and the
/// `MobileTerminalByteTee` for the raw output stream and replay.
@MainActor
final class TerminalSurfaceAttachBridge: SurfaceAttachBridge {
    func resolveTerminalSurface(reference: String) -> UUID? {
        guard let id = UUID(uuidString: reference) else { return nil }
        return TerminalSurfaceRegistry.shared.surface(id: id) != nil ? id : nil
    }

    func replayState(surfaceID: UUID) -> (seq: UInt64, data: Data)? {
        MobileTerminalByteTee.shared.replayState(surfaceID: surfaceID)
    }

    func subscribe(surfaceID: UUID, _ onBytes: @escaping @MainActor (Data) -> Void) -> Int {
        MobileTerminalByteTee.shared.addConsumer(surfaceID: surfaceID, onBytes)
    }

    func unsubscribe(surfaceID: UUID, token: Int) {
        MobileTerminalByteTee.shared.removeConsumer(surfaceID: surfaceID, token: token)
    }

    func writeInput(surfaceID: UUID, bytes: Data) {
        TerminalSurfaceRegistry.shared.surface(id: surfaceID)?.injectRawAttachInput(bytes)
    }

    func applyAttachmentSize(surfaceID: UUID, size: SurfaceSize) {
        _ = TerminalSurfaceRegistry.shared.surface(id: surfaceID)?
            .applyMobileViewportLimit(columns: size.cols, rows: size.rows, reason: "surfaceAttach")
    }

    func clearAttachmentSize(surfaceID: UUID) {
        _ = TerminalSurfaceRegistry.shared.surface(id: surfaceID)?
            .clearMobileViewportLimit(reason: "surfaceAttachDetach")
    }

    func requestRedraw(surfaceID: UUID) {
        TerminalSurfaceRegistry.shared.surface(id: surfaceID)?.forceRefresh(reason: "surfaceAttachRedraw")
    }
}
