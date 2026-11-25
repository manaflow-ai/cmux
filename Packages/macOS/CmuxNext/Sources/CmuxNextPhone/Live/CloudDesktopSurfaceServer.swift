public import CoreVideo
public import Foundation
import IOSurface
import os

private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")

/// Where a view-only surface's frames come from (a Cloud machine's VNC desktop): `start` hands
/// each newest framebuffer to `frame` on the main actor and calls `ended` once, with why, when the
/// stream ends by itself; `stop` ends it with no `ended`. A feed never takes input.
public struct SurfaceFrameFeed {
    public var start: @MainActor (_ frame: @escaping @MainActor (CVPixelBuffer) -> Void,
                                  _ ended: @escaping @MainActor (String) -> Void) -> Void
    public var stop: @MainActor () -> Void

    public init(start: @escaping @MainActor (_ frame: @escaping @MainActor (CVPixelBuffer) -> Void,
                                             _ ended: @escaping @MainActor (String) -> Void) -> Void,
                stop: @escaping @MainActor () -> Void) {
        self.start = start
        self.stop = stop
    }
}

/// A Cloud machine's desktop as a phone's streamed surface, view only: the same loopback `sf/1`
/// source as ``SimulatorSurfaceServer`` (cmux-mobile-host `surface.rs`), with frames from a
/// ``SurfaceFrameFeed`` (the machine's VNC framebuffer) encoded by the same
/// ``SurfaceFrameEncoder``. Frames coalesce to hostd's pace: a new framebuffer replaces the last
/// one and raises one `damage` until hostd asks for an `encode`. Every touch, text, key and button
/// from the phone is dropped; nothing reaches the machine.
///
/// It ends when its feed ends (the VNC stream closed), when ``stop()`` is called (the phone
/// stopped the surface, or the machine stopped running), or when its listener fails. Only a
/// client that sends its per-launch secret first is served; the listener takes loopback only.
@MainActor
public final class CloudDesktopSurfaceServer {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case listener(String), stopped

        public var description: String {
            switch self {
            case .listener(let reason): "the Cloud desktop source did not start: \(reason)"
            case .stopped: "the Cloud desktop source stopped while it started"
            }
        }
    }

    private let feed: SurfaceFrameFeed
    private let label: String
    public let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var listener: LoopbackListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var ready: [CheckedContinuation<UInt16, any Error>] = []
    /// The newest framebuffer (held, so its pool buffer is not reused while it may be encoded).
    private var latest: CVPixelBuffer?
    private var latestAt: UInt64 = 0
    /// Runs once when the source stops.
    public var onEnd: (@MainActor () -> Void)?

    /// `label` names the source in logs (the machine id; never a secret).
    public init(feed: SurfaceFrameFeed, label: String) {
        self.feed = feed
        self.label = label
    }

    /// Listens on `127.0.0.1`, starts the feed, and returns the port.
    public func start() async throws -> UInt16 {
        do {
            listener = try LoopbackListener(ready: { [weak self] in self?.listenerChanged($0) },
                                            accept: { [weak self] in self?.accept($0) })
        } catch {
            throw Failure.listener("\(error)")
        }
        // The desktop connects while hostd connects to us, so its first frame is near.
        feed.start({ [weak self] in self?.frame($0) }, { [weak self] reason in self?.feedEnded(reason) })
        guard listener != nil else { throw Failure.stopped }
        return try await withCheckedThrowingContinuation { ready.append($0) }
    }

    /// Whether the source still listens.
    public var isRunning: Bool { listener != nil }

    /// Stops the feed, stops listening and ends every session.
    public func stop() {
        guard listener != nil || !sessions.isEmpty else { return }
        listener?.cancel()
        listener = nil
        feed.stop()
        latest = nil
        for session in sessions.values { session.end() }
        sessions = [:]
        // A start still waiting for the port never hangs.
        let waiting = ready
        ready = []
        waiting.forEach { $0.resume(throwing: Failure.stopped) }
        let end = onEnd
        onEnd = nil
        end?()
    }

    private func listenerChanged(_ result: Result<UInt16, any Error>) {
        let waiting = ready
        ready = []
        switch result {
        case .success(let port):
            waiting.forEach { $0.resume(returning: port) }
        case .failure(let error):
            waiting.forEach { $0.resume(throwing: Failure.listener("\(error)")) }
            stop()
        }
    }

    private func feedEnded(_ reason: String) {
        logger.notice("cloud desktop source \(self.label, privacy: .public): the desktop stream ended: \(reason, privacy: .public)")
        stop()
    }

    private func frame(_ buffer: CVPixelBuffer) {
        guard listener != nil else { return }
        latest = buffer
        // hostd's clock: `CLOCK_UPTIME_RAW` in microseconds (`surface_clock_us`).
        latestAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000
        for session in sessions.values { session.frame(buffer, at: latestAt) }
    }

    private func accept(_ connection: LoopbackConnection) {
        let id = ObjectIdentifier(connection)
        let session = Session(connection: connection, secret: secret, label: label) { [weak self] in
            self?.sessions[id] = nil
        }
        sessions[id] = session
        session.start(latest: latest, at: latestAt)
    }
}

extension CloudDesktopSurfaceServer {
    /// One hostd connection: the hello, then frames out. Input lines are read and dropped.
    @MainActor
    final class Session {
        private let connection: LoopbackConnection
        private let secret: String
        private let label: String
        private let ended: @MainActor () -> Void
        private var wire = SurfaceSourceWire()
        private var authorized = false
        private var encoder: SurfaceFrameEncoder?
        private var latest: CVPixelBuffer?
        private var latestAt: UInt64 = 0
        /// A `damage` hostd has not asked to encode yet: one is enough.
        private var damageSent = false
        private var visible = true
        private var closed = false

        init(connection: LoopbackConnection, secret: String, label: String, ended: @escaping @MainActor () -> Void) {
            self.connection = connection
            self.secret = secret
            self.label = label
            self.ended = ended
        }

        /// `latest` is the server's newest frame so far, shown once hostd says hello.
        func start(latest: CVPixelBuffer?, at: UInt64) {
            self.latest = latest
            latestAt = at
            connection.start(ended: { [weak self] in self?.end() })
            receive()
        }

        func end() {
            guard !closed else { return }
            closed = true
            encoder = nil
            latest = nil
            connection.cancel()
            ended()
        }

        private func receive() {
            connection.receive(maximum: 64 * 1024) { [weak self] data, finished in
                guard let self, !self.closed else { return }
                if let data { self.wire.append(data) }
                do {
                    while let frame = try self.wire.next() { self.handle(frame) }
                } catch {
                    return self.end()
                }
                if finished { return self.end() }
                self.receive()
            }
        }

        private func fail(_ message: String) {
            logger.error("cloud desktop source \(self.label, privacy: .public): \(message, privacy: .public)")
            guard !closed else { return }
            connection.send(SurfaceSourceWire.json(["t": "error", "message": message]), sent: { [weak self] in self?.end() })
        }

        private func send(_ data: Data) {
            guard !closed else { return }
            connection.send(data)
        }

        private func handle(_ frame: SurfaceSourceWire.Frame) {
            guard case .json(let line) = frame else { return end() }
            let type = line["t"]?.string
            guard authorized else {
                guard type == "hello", let given = line["secret"]?.string, Self.equal(given, secret) else {
                    return fail("unauthorized")
                }
                authorized = true
                if let latest { self.frame(latest, at: latestAt) }
                return
            }
            switch type {
            case "encode": encode(idr: line["idr"]?.bool ?? false, kbps: SurfaceFrameEncoder.bitrate(fromWire: line["kbps"]?.number))
            case "visible": setVisible(line["visible"]?.bool ?? true)
            // View only: the phone's touches, text, keys and buttons never reach the machine.
            default: break
            }
        }

        private static func equal(_ a: String, _ b: String) -> Bool {
            let a = Array(a.utf8), b = Array(b.utf8)
            guard a.count == b.count else { return false }
            return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }

        /// The newest framebuffer: a new size makes a new encoder (its first frame is an IDR) and
        /// tells hostd; otherwise at most one `damage` waits for hostd's `encode`.
        func frame(_ buffer: CVPixelBuffer, at: UInt64) {
            guard !closed else { return }
            let first = latest == nil
            latest = buffer
            latestAt = at
            guard authorized else { return }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            if encoder.map({ $0.sourceWidth != width || $0.sourceHeight != height }) ?? true {
                encoder?.finish()
                encoder = SurfaceFrameEncoder(sourceWidth: width, sourceHeight: height)
                guard encoder != nil else {
                    return fail("VideoToolbox gave no H.264 encoder for this desktop")
                }
                let size = SurfaceFrameEncoder.encodedSize(width: width, height: height)
                send(SurfaceSourceWire.json(["t": "size", "width": size.width, "height": size.height]))
                if !first { damageSent = false }
            }
            guard visible, !damageSent else { return }
            damageSent = true
            send(SurfaceSourceWire.json(["t": "damage"]))
        }

        private func encode(idr: Bool, kbps: Int) {
            damageSent = false
            // The VNC client's frames are IOSurface-backed (CmuxVNC `FramePublisher`).
            guard let encoder, let buffer = latest, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
                return send(SurfaceSourceWire.json(["t": "skip"]))
            }
            encoder.setBitrate(kbps: kbps)
            let captured = latestAt
            let connection = connection
            encoder.encode(surface, forceKeyframe: idr) { result in
                guard let result else { return connection.sendFromAnyThread(SurfaceSourceWire.json(["t": "skip"])) }
                connection.sendFromAnyThread(SurfaceSourceWire.accessUnit(idr: result.keyframe, captureMicros: captured, annexB: result.data))
            }
        }

        /// A hidden card costs no encoding: frames stop asking hostd for an encode until it shows again.
        private func setVisible(_ shown: Bool) {
            guard shown != visible else { return }
            visible = shown
            if shown, let latest {
                damageSent = false
                frame(latest, at: latestAt)
            }
        }
    }
}
