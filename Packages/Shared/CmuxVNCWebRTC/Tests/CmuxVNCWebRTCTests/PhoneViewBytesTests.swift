#if os(macOS)
@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// What a phone looking at a native dev build costs on the wire (RFD 0088,
/// slice 3b): the host's real path (`ScreenStreamHost.serve`, libwebrtc's
/// hardware H.264 encoder, `applyVideo`'s sender parameters) to a viewer, in
/// one process over host ICE candidates, from a synthetic screen that, like
/// ScreenCaptureKit, delivers a picture only when something on it changed.
///
/// The picture is 1280×828: a 14" MacBook Pro's 3024×1964 at the 1280 rung
/// a portrait iPhone's viewer demand captures at (cmux-rd-screen `demand`).
/// The workloads are the ones RFD 0088 prices: an idle screen (target:
/// nothing), typing, a native app animating 1 s in every 5 (20% duty;
/// target 0.5 to 1 Mbit/s while changing, about 0.1 GB an hour), and a
/// full-screen scroll for the old constant-video case, at the phone size and
/// at the display's own size.
///
/// Heavy (hardware encode, about 50 s a case) and timing-bound, so it runs
/// only when asked: `CMUX_VNC_PHONE_BYTES=1`
/// (scripts/measure/mac-screen-phone-bytes.sh). Prints one
/// `MAC-SCREEN-PHONE-BYTES` line a case; asserts only that a picture arrived.
@Suite(.serialized)
struct PhoneViewBytesTests {
    static let enabled = ProcessInfo.processInfo.environment["CMUX_VNC_PHONE_BYTES"] == "1"
    /// Seconds to warm up (congestion control starts near 300 kbit/s) and to measure.
    static let warmUp = Double(ProcessInfo.processInfo.environment["CMUX_VNC_PHONE_BYTES_WARMUP"] ?? "") ?? 15
    static let window = Double(ProcessInfo.processInfo.environment["CMUX_VNC_PHONE_BYTES_WINDOW"] ?? "") ?? 30

    @Test(.enabled(if: enabled), .timeLimit(.minutes(3)), arguments: DevBuildScreen.Workload.allCases)
    func aPhoneViewOfANativeDevBuild(workload: DevBuildScreen.Workload) async throws {
        let (hostSide, viewerSide) = LoopbackSignaling.pair()
        let lines = PhoneLogLines()
        let size = workload == .fullSizeScroll ? (3024, 1964) : (1280, 828)
        let source = DevBuildScreen(width: size.0, height: size.1, workload: workload)
        let host = ScreenStreamHost(name: "MacBook Pro", backend: { source }, log: { line in lines.append(line) })
        let hostTask = Task { try? await host.serve(hostSide) }
        defer { hostTask.cancel() }

        let counter = ScreenStreamTests.FrameCounter()
        let viewer = ScreenStreamViewer(signaling: viewerSide)
        viewer.onVideo = { $0.track.add(counter) }
        try await viewer.connect()
        defer {
            viewer.close()
            host.disconnectViewer()
        }
        viewer.setQuality(.auto)
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.snapshot.0 > 0, "no picture arrived")

        try await Task.sleep(for: .seconds(Self.warmUp))
        let before = await viewer.videoStats()
        let changesBefore = source.changes
        let start = ContinuousClock.now
        try await Task.sleep(for: .seconds(Self.window))
        let after = await viewer.videoStats()
        let changes = source.changes - changesBefore
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let videoBytes = after.bytesReceived - before.bytesReceived
        let wireBytes = after.transportBytesReceived - before.transportBytesReceived
        func kbps(_ bytes: Double) -> String { String(format: "%.1f", bytes * 8 / seconds / 1000) }
        let gbPerHour = wireBytes / seconds * 3600 / 1e9
        // Over the seconds the picture changed (the 20% duty case: the animating fifth).
        let busy = workload.busyFraction
        let busyMbps = busy > 0 ? wireBytes * 8 / (seconds * busy) / 1e6 : 0
        let picture = counter.snapshot.1
        print("""
        MAC-SCREEN-PHONE-BYTES workload=\(workload.rawValue) size=\(Int(picture.width))x\(Int(picture.height)) \
        seconds=\(String(format: "%.1f", seconds)) source_changes=\(changes) \
        frames_received=\(Int(after.framesReceived - before.framesReceived)) \
        video_kbps=\(kbps(videoBytes)) wire_kbps=\(kbps(wireBytes)) \
        busy_mbps=\(busy > 0 ? String(format: "%.2f", busyMbps) : "-") gb_per_hour=\(String(format: "%.4f", gbPerHour)) \
        codec=\(after.codec ?? "?") decoder=\(after.decoder ?? "?")
        """)
        for line in lines.matching("video:").suffix(2) { print("MAC-SCREEN-PHONE-BYTES encoder \(line)") }
    }
}

/// The host's log lines, for the encoder's own numbers.
private final class PhoneLogLines: @unchecked Sendable {
    // @unchecked: `lines` is behind `lock`.
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func matching(_ prefix: String) -> [String] { lock.withLock { lines.filter { $0.hasPrefix(prefix) } } }
}

/// A Mac display showing a native app under development, delivering a
/// picture only when it changed (as ScreenCaptureKit does: a still screen
/// sends nothing). NV12, IOSurface-backed. Text-like content: glyph-sized
/// blocks on white.
final class DevBuildScreen: ScreenBackend, @unchecked Sendable {
    // @unchecked: the canvas and timer are touched only on `queue`; `changeCount` is behind `lock`.
    enum Workload: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// One picture, then nothing.
        case idle
        /// A glyph typed every 125 ms (8 a second) into a line of text.
        case typing
        /// A 480×320 region animating at 60 fps for 1 s in every 5, still otherwise.
        case app20
        /// The whole picture scrolling 8 rows a frame at 60 fps.
        case scroll
        /// ``scroll`` at the display's own 3024×1964 (no viewer demand).
        case fullSizeScroll

        var testDescription: String { rawValue }

        /// The share of the time the picture changes.
        var busyFraction: Double {
            switch self {
            case .idle: 0
            case .typing, .scroll, .fullSizeScroll: 1
            case .app20: 0.2
            }
        }
    }

    let width: Int
    let height: Int
    let workload: Workload
    private let queue = DispatchQueue(label: "dev-build-screen", qos: .userInteractive)
    private var timer: (any DispatchSourceTimer)?
    private var pool: CVPixelBufferPool?
    private var canvas: [UInt8]
    private var tick = 0
    private var caret = 0
    private let lock = NSLock()
    private var changeCount = 0

    init(width: Int, height: Int, workload: Workload) {
        self.width = width
        self.height = height
        self.workload = workload
        canvas = Self.text(width: width, rows: height * 2, seed: 7)
    }

    /// Pictures delivered so far.
    var changes: Int { lock.withLock { changeCount } }

    /// A page of glyph-sized blocks of light and dark on white, `rows` tall.
    static func text(width: Int, rows: Int, seed: UInt64) -> [UInt8] {
        var generator = SeededGenerator(seed: seed)
        var pixels = [UInt8](repeating: 235, count: width * rows)
        for line in stride(from: 0, to: rows, by: 24) {
            var x = 8
            while x < width - 16 {
                let glyph = Int.random(in: 6 ... 12, using: &generator)
                if Int.random(in: 0 ..< 6, using: &generator) > 0 {
                    let shade = UInt8.random(in: 16 ... 96, using: &generator)
                    for y in line + 4 ..< min(line + 18, rows) {
                        for dx in 0 ..< glyph where Int.random(in: 0 ..< 3, using: &generator) > 0 { pixels[y * width + x + dx] = shade }
                    }
                } else {
                    x += 8
                }
                x += glyph + 2
            }
        }
        return pixels
    }

    var maximumFrameRate: Int? { 60 }

    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        displays([CGSize(width: width, height: height)], 0)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        queue.sync {
            pool = created
            // The first picture, whatever the workload.
            if let buffer = render(scroll: 0) { deliver(buffer, rect: rect, frame) }
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            guard changed(at: tick), let buffer = render(scroll: workload == .scroll || workload == .fullSizeScroll ? tick * 8 : 0) else { return }
            deliver(buffer, rect: rect, frame)
        }
        self.timer = timer
        timer.resume()
    }

    private func deliver(_ buffer: CVPixelBuffer, rect: CGRect, _ frame: @Sendable (CVPixelBuffer, CGRect) -> Void) {
        lock.withLock { changeCount += 1 }
        frame(buffer, rect)
    }

    /// Changes the canvas for tick `tick` (60 a second); false when nothing changed.
    private func changed(at tick: Int) -> Bool {
        switch workload {
        case .idle:
            return false
        case .typing:
            guard tick % 8 == 0 else { return false } // 125 ms at 60 ticks a second
            // The next glyph on line 10, wrapping to the line's start.
            let line = 10 * 24, cell = 12
            let x = 8 + (caret % ((width - 32) / cell)) * cell
            caret += 1
            let shade = UInt8(16 + (caret * 37) % 80)
            for y in line + 4 ..< line + 18 {
                for dx in 0 ..< 8 { canvas[y * width + x + dx] = (dx + y + caret) % 3 == 0 ? 235 : shade }
            }
            return true
        case .app20:
            guard tick % 300 < 60 else { return false } // 1 s in every 5
            // A 480×320 panel: bars that slide 6 px a frame over a gradient.
            let left = width / 2 - 240, top = height / 2 - 160
            for y in 0 ..< 320 {
                let row = (top + y) * width + left
                for x in 0 ..< 480 {
                    canvas[row + x] = ((x + tick * 6) / 24) % 2 == 0 ? UInt8(40 + y / 4) : UInt8(200 - y / 8)
                }
            }
            return true
        case .scroll, .fullSizeScroll:
            return true
        }
    }

    /// The canvas as a picture, scrolled `scroll` rows.
    private func render(scroll: Int) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let rows = canvas.count / width
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            canvas.withUnsafeBufferPointer { pixels in
                guard let base = pixels.baseAddress else { return }
                for y in 0 ..< height {
                    memcpy(luma + y * stride, base + ((y + scroll) % rows) * width, width)
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return buffer
    }

    func select(display index: Int) {}
    func handle(_ input: ScreenInput) {}

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}

/// SplitMix64: the same page every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
