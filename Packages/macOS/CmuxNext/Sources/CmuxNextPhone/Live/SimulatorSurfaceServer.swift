public import Foundation
import IOSurface
import os

private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")

/// A booted simulator as a phone's streamed surface: the `sf/1` source
/// cmux-mobile-host connects to on loopback (cmux-mobile-host `surface.rs`,
/// cmux-next-ios/verify/simulator-surface.md). It hands hostd the simulator's
/// own frames (SimulatorKit's IOSurface, the one the Mac's phone tab shows;
/// never a screen capture), encoded to H.264 when hostd's media engine asks,
/// and drives the simulator with the touches, text, keys and buttons hostd
/// passes on: touches through the same SimulatorKit HID path as the Mac's tab
/// (0...1 of the screen in the orientation shown, so device size and rotation
/// need no mapping), text and buttons through ``PhoneService`` (so a recording
/// logs them and text a US keyboard cannot type is pasted).
///
/// Only a client that sends this source's per-launch secret first is served;
/// the listener takes loopback connections only.
@MainActor
public final class SimulatorSurfaceServer {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case notSimulator, noLiveScreen, listener(String)

        public var description: String {
            switch self {
            case .notSimulator: "only a booted iOS simulator streams to a phone"
            case .noLiveScreen: "this Xcode gives no live simulator screen"
            case .listener(let reason): "the surface source did not start: \(reason)"
            }
        }
    }

    private let service: PhoneService
    private let device: PhoneDeviceID
    public let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var listener: LoopbackListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var ready: [CheckedContinuation<UInt16, any Error>] = []
    /// Runs once when the source stops (``stop()``, or its listener failed).
    public var onEnd: (@MainActor () -> Void)?
    /// Whether the phone tab this source streams still shows this simulator. Asked on
    /// every input and frame (a dictionary lookup); false stops the source, so a tab
    /// closed or switched to another phone is never streamed or driven again.
    public var stillShown: (@MainActor () -> Bool)?

    public init(service: PhoneService, device: PhoneDeviceID) {
        self.service = service
        self.device = device
    }

    /// Listens on `127.0.0.1` and returns the port.
    public func start() async throws -> UInt16 {
        guard device.mode == .simulator else { throw Failure.notSimulator }
        guard let live = service.live, live.isAvailable() else { throw Failure.noLiveScreen }
        do {
            listener = try LoopbackListener(ready: { [weak self] in self?.listenerChanged($0) },
                                            accept: { [weak self] in self?.accept($0) })
        } catch {
            throw Failure.listener("\(error)")
        }
        return try await withCheckedThrowingContinuation { ready.append($0) }
    }

    /// Whether the source still listens (``stop()`` not called, its listener not failed).
    public var isRunning: Bool { listener != nil }

    /// Stops listening and ends every session.
    public func stop() {
        guard listener != nil || !sessions.isEmpty else { return }
        listener?.cancel()
        listener = nil
        for session in sessions.values { session.end() }
        sessions = [:]
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

    private func accept(_ connection: LoopbackConnection) {
        guard let live = service.live else { return connection.cancel() }
        let id = ObjectIdentifier(connection)
        let session = Session(connection: connection, secret: secret, udid: device.raw, device: device, live: live, service: service,
                              stillShown: { [weak self] in self?.stillShown?() ?? true },
                              stale: { [weak self] in self?.stop() }) { [weak self] in
            self?.sessions[id] = nil
        }
        sessions[id] = session
        session.start()
    }
}

extension SimulatorSurfaceServer {
    /// One hostd connection: the hello, then frames out and input in.
    @MainActor
    final class Session {
        private let connection: LoopbackConnection
        private let secret: String
        private let udid: String
        private let device: PhoneDeviceID
        private let live: SimulatorKitHID
        private let service: PhoneService
        private let ended: @MainActor () -> Void
        private let stillShown: @MainActor () -> Bool
        private let stale: @MainActor () -> Void
        /// The phone's input, applied one at a time in order: touches and keys at once,
        /// text and buttons through ``PhoneService`` (text a US keyboard cannot type
        /// is pasted with simctl). Bounded: a flood drops new input, never spawns more. A dropped
        /// touch `ended` or key up is covered by hostd, which lifts a finger and releases held keys
        /// when the engine gives up on held input and when the viewer goes.
        private let inputs: AsyncStream<[String: SurfaceSourceValue]>
        private let queue: AsyncStream<[String: SurfaceSourceValue]>.Continuation
        private var applying: Task<Void, Never>?
        static let inputBacklog = 256
        private var wire = SurfaceSourceWire()
        private var authorized = false
        private var watch: SimulatorKitHID.ScreenWatch?
        private var encoder: SurfaceFrameEncoder?
        private var latest: IOSurface?
        /// When the newest frame arrived (µs on hostd's clock).
        private var latestAt: UInt64 = 0
        /// A `damage` hostd has not asked to encode yet: one is enough.
        private var damageSent = false
        private var visible = true
        private var closed = false

        init(connection: LoopbackConnection, secret: String, udid: String, device: PhoneDeviceID, live: SimulatorKitHID,
             service: PhoneService, stillShown: @escaping @MainActor () -> Bool, stale: @escaping @MainActor () -> Void,
             ended: @escaping @MainActor () -> Void) {
            (inputs, queue) = AsyncStream.makeStream(of: [String: SurfaceSourceValue].self,
                                                     bufferingPolicy: .bufferingOldest(Self.inputBacklog))
            self.stillShown = stillShown
            self.stale = stale
            self.connection = connection
            self.secret = secret
            self.udid = udid
            self.device = device
            self.live = live
            self.service = service
            self.ended = ended
        }

        func start() {
            connection.start(ended: { [weak self] in self?.end() })
            let inputs = inputs
            // task-owner: the session's one input applier; ends with the stream in end()
            applying = Task { [weak self] in
                for await line in inputs {
                    guard let self, !self.closed else { return }
                    await self.apply(line)
                }
            }
            receive()
        }

        func end() {
            guard !closed else { return }
            closed = true
            if let watch { live.stopScreen(watch) }
            watch = nil
            encoder = nil
            queue.finish()
            applying?.cancel()
            connection.cancel()
            ended()
        }

        /// hostd's clock: `CLOCK_UPTIME_RAW` in microseconds (`surface_clock_us`).
        static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }

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

        /// Tells hostd why the stream cannot go on (it logs the reason), then ends once that line is out.
        private func fail(_ message: String) {
            logger.error("surface source \(self.udid, privacy: .public): \(message, privacy: .public)")
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
                return startFrames()
            }
            switch type {
            case "encode": encode(idr: line["idr"]?.bool ?? false, kbps: Int(line["kbps"]?.number ?? 4000))
            case "visible": setVisible(line["visible"]?.bool ?? true)
            case "touch", "text", "key", "button":
                guard stillShown() else {
                    logger.notice("surface source \(self.udid, privacy: .public): its tab no longer shows this simulator")
                    return stale()
                }
                queue.yield(line)
            default: break
            }
        }

        private static func equal(_ a: String, _ b: String) -> Bool {
            let a = Array(a.utf8), b = Array(b.utf8)
            guard a.count == b.count else { return false }
            return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }

        // MARK: Frames

        private func startFrames() {
            guard stillShown() else { return stale() }
            do {
                let started = try live.startScreen(udid) { [weak self] surface in self?.frame(surface) }
                // The first frame arrives inside startScreen and may have ended the session
                // (its tab stopped showing this simulator): the watch must not outlive it.
                guard !closed else { return live.stopScreen(started) }
                watch = started
            } catch {
                return fail("no live screen for this simulator: \(error)")
            }
            guard latest != nil else {
                return fail("the simulator shows no screen yet")
            }
        }

        private func frame(_ surface: IOSurface) {
            guard stillShown() else {
                logger.notice("surface source \(self.udid, privacy: .public): its tab no longer shows this simulator")
                return stale()
            }
            let first = latest == nil
            latest = surface
            latestAt = Self.now()
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            if encoder.map({ $0.sourceWidth != width || $0.sourceHeight != height }) ?? true {
                // A new size (first frame, a rotation): a new encoder, whose first frame is an IDR.
                encoder?.finish()
                encoder = SurfaceFrameEncoder(sourceWidth: width, sourceHeight: height)
                guard encoder != nil else {
                    return fail("VideoToolbox gave no H.264 encoder for this screen")
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
            guard stillShown() else { return stale() }
            guard let encoder, let surface = latest ?? live.currentSurface(udid) else {
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

        /// A hidden phone tab costs no encoding: frames stop asking hostd for an encode until it is shown again.
        private func setVisible(_ shown: Bool) {
            guard shown != visible else { return }
            visible = shown
            if shown {
                damageSent = false
                if let surface = latest { frame(surface) }
            }
        }

        // MARK: Input

        private func touch(_ line: [String: SurfaceSourceValue]) {
            guard let x = line["x"]?.number, let y = line["y"]?.number, x.isFinite, y.isFinite else { return }
            let phase: PhoneTouch.Phase
            switch line["phase"]?.string {
            case "began": phase = .began
            case "moved": phase = .moved
            case "ended": phase = .ended
            default: return
            }
            try? live.touchNow(phase, x: min(max(x, 0), 1), y: min(max(y, 0), 1), udid: udid)
        }

        private func key(_ line: [String: SurfaceSourceValue]) {
            guard let usage = line["key"]?.string.flatMap(Self.keyUsage), let down = line["down"]?.bool else { return }
            try? live.keyNow(usage, down: down, udid: udid)
        }

        /// The HID keyboard usages of the keys a phone may press (hostd's list).
        static func keyUsage(_ code: String) -> UInt32? {
            switch code {
            case "Enter": 0x28
            case "Escape": 0x29
            case "Backspace": 0x2A
            case "Tab": 0x2B
            case "Delete": 0x4C
            case "ArrowRight": 0x4F
            case "ArrowLeft": 0x50
            case "ArrowDown": 0x51
            case "ArrowUp": 0x52
            default: nil
            }
        }

        /// One queued input, in order (see ``inputs``).
        private func apply(_ line: [String: SurfaceSourceValue]) async {
            switch line["t"]?.string {
            case "touch": touch(line)
            case "key": key(line)
            case "text": if let text = line["text"]?.string { await act(.text(text)) }
            case "button":
                switch line["button"]?.string {
                case "home": await act(.button(.home))
                case "lock": await act(.button(.lock))
                default: break
                }
            default: break
            }
        }

        /// Sends `input` through ``PhoneService``, which logs it into a running recording.
        private func act(_ input: PhoneInput) async {
            try? await service.send(input, to: device)
        }
    }
}
