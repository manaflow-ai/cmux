#if os(macOS)
@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// A screen stream at 120 fps end to end in one process: the host's real
/// path (`ScreenStreamHost.serve`, libwebrtc's hardware H.264 encoder, the
/// sender parameters `applyVideo` sets) to a viewer that reports a 120 Hz
/// display, over host ICE candidates and in-memory signaling. The source is
/// a 16" MacBook Pro's built-in display (3456×2234) scrolling at 120 fps.
///
/// Heavy (hardware encode and decode at 120 fps for about 30 s) and
/// timing-bound, so it runs only when asked: `CMUX_VNC_120FPS=1`
/// (scripts/measure/mac-screen-120fps.sh), on an otherwise quiet Mac. One
/// case at a time: two streams would share the hardware encoder.
@Suite(.serialized)
struct HighFrameRateStreamTests {
    static let enabled = ProcessInfo.processInfo.environment["CMUX_VNC_120FPS"] == "1"

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)), arguments: [ScreenQuality.auto, .smooth])
    func aProMotionScreenStreamsAt120Fps(quality: ScreenQuality) async throws {
        let run = try await Self.stream(quality: quality, source: ScrollingScreen(width: 3456, height: 2234, fps: 120), viewerHz: 120)
        let size = run.size
        #expect(run.agreed == 120, "the host agreed on 120 fps with a 120 Hz viewer")
        // Never more than the hardware encoder sustains at 120 fps (ScreenQuality.maximumEncodedPixelRate).
        // Auto keeps that size; Smooth Motion lets WebRTC lower it further to hold the frame rate, as at 60.
        let pixelRate = size.width * size.height * 120
        #expect(pixelRate <= Double(ScreenQuality.maximumEncodedPixelRate) * 1.01,
                "streamed at \(Int(size.width))x\(Int(size.height)), \(Int(pixelRate / 1e6)) Mpixel/s")
        if quality == .auto {
            #expect(pixelRate >= Double(ScreenQuality.maximumEncodedPixelRate) * 0.97, "Auto scales no more than the encoder needs")
        }
        #expect(run.sourceFps >= 115, "the synthetic source itself kept 120 fps (the Mac was too busy to measure)")
        #expect(run.decodedFps >= 110, "a 120 fps stream decodes at \(Int(run.decodedFps)) fps")
        #expect(run.latency.count > 0, "no stamped frame was read back")
    }

    /// A 60 Hz iPhone (iPhone 16 Plus) viewing a 120 Hz Mac: the stream agrees on 60 fps.
    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)))
    func aSixtyHertzViewerStreamsAt60Fps() async throws {
        let run = try await Self.stream(quality: .auto, source: ScrollingScreen(width: 3024, height: 1964, fps: 120), viewerHz: 60)
        #expect(run.agreed == 60, "the host agreed on 60 fps with a 60 Hz viewer")
        #expect(run.decodedFps >= 55, "a 60 fps stream decodes at \(Int(run.decodedFps)) fps")
        #expect(run.latency.count > 0, "no stamped frame was read back")
    }

    struct Run {
        var agreed: Int?
        var sourceFps: Double
        var decodedFps: Double
        var size: CGSize
        var latency: StreamLatencySummary
    }

    /// Streams `source` to a viewer with a `viewerHz` display at `quality`, waits 20 s for
    /// congestion control to ramp up, and measures a 6 s window: received and decoded fps,
    /// and each distinct frame's latency from the source to the viewer's decoded picture
    /// (``StreamLatencyReader``). Prints one MAC-SCREEN-120FPS line and its latency line.
    static func stream(quality: ScreenQuality, source: ScrollingScreen, viewerHz: Int) async throws -> Run {
        let (hostSide, viewerSide) = LoopbackSignaling.pair()
        let lines = LogLines()
        let host = ScreenStreamHost(name: "MacBook Pro", backend: { source }, log: { line in
            lines.append(line)
            print("host: \(line)")
        })
        let hostTask = Task { try? await host.serve(hostSide) }
        defer { hostTask.cancel() }

        let counter = ScreenStreamTests.FrameCounter()
        let reader = StreamLatencyReader(sourceWidth: source.width) { source.deliveredAt(stamp: $0) }
        let viewer = ScreenStreamViewer(signaling: viewerSide)
        viewer.onVideo = {
            $0.track.add(counter)
            $0.track.add(reader)
        }
        let agreed = AgreedRate()
        viewer.onDisplays = { message in if let fps = message.fps { agreed.set(fps) } }
        try await viewer.connect()
        defer {
            viewer.close()
            host.disconnectViewer()
        }
        viewer.setDisplayFrameRate(viewerHz)
        viewer.setQuality(quality)
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.snapshot.0 > 0, "no picture arrived")

        // Let congestion control ramp up (it starts near 300 kbit/s), then measure a 6 s window.
        try await Task.sleep(for: .seconds(20)) // warm-up
        let before = await viewer.videoStats()
        let start = ContinuousClock.now
        let since = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(for: .seconds(6)) // measurement window
        let after = await viewer.videoStats()
        let latency = reader.window(since: since)
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let decodedFps = (after.framesDecoded - before.framesDecoded) / seconds
        let receivedFps = (after.framesReceived - before.framesReceived) / seconds
        let mbps = (after.bytesReceived - before.bytesReceived) * 8 / seconds / 1_000_000
        let decodeMs = (after.framesDecoded - before.framesDecoded) > 0
            ? (after.totalDecodeTime - before.totalDecodeTime) / (after.framesDecoded - before.framesDecoded) * 1000 : .nan
        let size = counter.snapshot.1
        let label = "quality=\(quality.rawValue) viewer_hz=\(viewerHz)"
        print("""
        MAC-SCREEN-120FPS \(label) agreed=\(agreed.value.map(String.init) ?? "-") \
        source=\(String(format: "%.1f", source.deliveredFps)) received=\(String(format: "%.1f", receivedFps)) \
        decoded=\(String(format: "%.1f", decodedFps)) dropped=\(Int(after.framesDropped - before.framesDropped)) \
        size=\(Int(size.width))x\(Int(size.height)) mbps=\(String(format: "%.1f", mbps)) \
        decoder=\(after.decoder ?? "?") codec=\(after.codec ?? "?")
        """)
        print("MAC-SCREEN-120FPS latency \(label) source_to_decoded \(latency) decode_ms=\(String(format: "%.2f", decodeMs)) jitter_buffer_ms=\(after.jitterBufferMs.map { String(format: "%.1f", $0) } ?? "-")")
        for line in lines.matching("video:").suffix(2) { print("MAC-SCREEN-120FPS encoder \(line)") }
        return Run(agreed: agreed.value, sourceFps: source.deliveredFps, decodedFps: decodedFps, size: size, latency: latency)
    }
}

/// The agreed rate from the host's displays message.
private final class AgreedRate: @unchecked Sendable {
    // @unchecked: `stored` is behind `lock`.
    private let lock = NSLock()
    private var stored: Int?
    func set(_ fps: Int) { lock.withLock { stored = fps } }
    var value: Int? { lock.withLock { stored } }
}

/// The host's log lines, for the encoder's own numbers.
private final class LogLines: @unchecked Sendable {
    // @unchecked: `lines` is behind `lock`.
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func matching(_ prefix: String) -> [String] { lock.withLock { lines.filter { $0.hasPrefix(prefix) } } }
}

/// One side of in-memory signaling: what one side sends, the other receives.
/// The viewer's side starts with `hello(peerPresent: true)`, so it offers at once.
final class LoopbackSignaling: ScreenSignaling, @unchecked Sendable {
    // @unchecked: `peer` is set once by `pair()` before either side is used, and cleared under `lock`.
    let endsSessionOnClose = true
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>
    private let inbox: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
    private let lock = NSLock()
    private var peer: LoopbackSignaling?

    private init() {
        (stream, inbox) = AsyncThrowingStream.makeStream(of: ScreenSignal.self)
    }

    static func pair() -> (host: LoopbackSignaling, viewer: LoopbackSignaling) {
        let host = LoopbackSignaling(), viewer = LoopbackSignaling()
        host.peer = viewer
        viewer.peer = host
        viewer.inbox.yield(.hello(peerPresent: true))
        return (host, viewer)
    }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }

    func send(_ signal: ScreenSignal) async throws {
        lock.withLock { peer }?.inbox.yield(signal)
    }

    /// Host candidates only: both ends are on this Mac.
    func iceServers() async throws -> [ICEServerConfig] { [] }

    func close() {
        inbox.finish()
        lock.withLock { peer = nil }
    }
}

/// A display scrolling a text-like texture 8 rows a frame at `fps`, as a
/// fast scroll on a 120 Hz screen: every frame differs, and most of it is
/// motion the encoder can predict. NV12, IOSurface-backed, as
/// ScreenCaptureKit delivers.
final class ScrollingScreen: ScreenBackend, @unchecked Sendable {
    // @unchecked: the timer's state is touched only on `queue`; the counters are behind `lock`.
    let width: Int
    let height: Int
    let fps: Int
    private let queue = DispatchQueue(label: "scrolling-screen", qos: .userInteractive)
    private var timer: (any DispatchSourceTimer)?
    private var pool: CVPixelBufferPool?
    private let texture: [UInt8]
    private let textureRows: Int
    private var index = 0
    private let lock = NSLock()
    private var delivered: [UInt64] = []
    /// When each stamped frame was handed to the host, by its 16-bit stamp (``FrameStamp``).
    private var stampedAt = [UInt64](repeating: 0, count: 1 << 16)

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        // Glyph-sized blocks of light and dark on white, repeating every 1024 rows.
        textureRows = 1024
        var generator = SystemRandomNumberGenerator()
        var rows = [UInt8](repeating: 235, count: width * textureRows)
        for line in stride(from: 0, to: textureRows, by: 24) {
            var x = 8
            while x < width - 16 {
                let glyph = Int.random(in: 6 ... 12, using: &generator)
                if Int.random(in: 0 ..< 6, using: &generator) > 0 {
                    let shade = UInt8.random(in: 16 ... 96, using: &generator)
                    for y in line + 4 ..< min(line + 18, textureRows) {
                        for dx in 0 ..< glyph where Int.random(in: 0 ..< 3, using: &generator) > 0 { rows[y * width + x + dx] = shade }
                    }
                } else {
                    x += 8
                }
                x += glyph + 2
            }
        }
        texture = rows
    }

    var maximumFrameRate: Int? { fps }

    /// When the frame stamped `stamp` was handed to the host (uptime ns), or nil.
    func deliveredAt(stamp: UInt16) -> UInt64? {
        lock.withLock { stampedAt[Int(stamp)] == 0 ? nil : stampedAt[Int(stamp)] }
    }

    /// Frames delivered per second over the last 2 s.
    var deliveredFps: Double {
        lock.withLock {
            guard let last = delivered.last else { return 0 }
            let recent = delivered.filter { last - $0 <= 2_000_000_000 }
            guard let first = recent.first, recent.count > 1, last > first else { return 0 }
            return Double(recent.count - 1) / (Double(last - first) / 1e9)
        }
    }

    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        pool = created
        displays([CGSize(width: width, height: height)], 0)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self, let (buffer, stamp) = next() else { return }
            lock.withLock {
                let now = DispatchTime.now().uptimeNanoseconds
                delivered.append(now)
                stampedAt[Int(stamp)] = now
                if delivered.count > 1000 { delivered.removeFirst(delivered.count - 1000) }
            }
            frame(buffer, CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.timer = timer
        timer.resume()
    }

    /// The next picture: the texture scrolled 8 more rows, stamped with its index.
    private func next() -> (CVPixelBuffer, UInt16)? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let offset = (index * 8) % textureRows
        let stamp = UInt16(truncatingIfNeeded: index)
        index += 1
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            texture.withUnsafeBufferPointer { rows in
                guard let base = rows.baseAddress else { return }
                for y in 0 ..< height {
                    memcpy(luma + y * stride, base + ((y + offset) % textureRows) * width, width)
                }
            }
            FrameStamp.draw(stamp, into: luma.assumingMemoryBound(to: UInt8.self), stride: stride)
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return (buffer, stamp)
    }

    func select(display index: Int) {}
    func handle(_ input: ScreenInput) {}
    func setFrameRate(_ fps: Int) {}

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}
#endif
