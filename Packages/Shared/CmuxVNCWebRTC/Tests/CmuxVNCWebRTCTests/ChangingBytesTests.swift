#if os(macOS)
@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// The bytes a stream costs while part of the screen changes (RFD 0088
/// slice 3b), end to end in one process through the host's real path. Each
/// run first scrolls the whole screen (congestion control ramps up, as after
/// a real scroll), then measures a typed line, a scrolling pane and a
/// full-screen scroll. Prints CHANGING-BYTES lines.
@Suite(.serialized)
struct ChangingBytesTests {
    struct Result {
        var kbps: Double
        var size: CGSize = .zero
        var fps: Double
        var qp: Double
    }

    /// One stream through the phases; returns each measured phase.
    static func measure(label: String, width: Int = 1280, height: Int = 800) async throws -> [String: Result] {
        let (hostSide, viewerSide) = LoopbackSignaling.pair()
        let source = ChangingScreen(width: width, height: height)
        let lines = HostLines()
        let host = ScreenStreamHost(name: "Mac", backend: { source }, log: { lines.append($0) })
        let hostTask = Task { try? await host.serve(hostSide) }
        defer { hostTask.cancel() }
        let counter = ScreenStreamTests.FrameCounter()
        let viewer = ScreenStreamViewer(signaling: viewerSide)
        viewer.onVideo = { $0.track.add(counter) }
        source.set(.full)
        try await viewer.connect()
        defer {
            viewer.close()
            host.disconnectViewer()
        }
        // task-owner: bounded wait for the first picture
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.snapshot.0 > 0, "no picture arrived")
        try await Task.sleep(for: .seconds(10)) // warm-up: congestion control ramps on a full-screen scroll
        var results: [String: Result] = [:]
        let phases: [(ChangingScreen.Phase, Int)] = [(.typing, 2), (.pane, 2), (.full, 1)]
        for (phase, settle) in phases {
            source.set(phase)
            try await Task.sleep(for: .seconds(settle)) // the encoder settles on the new content
            let before = await viewer.videoStats()
            let start = ContinuousClock.now
            try await Task.sleep(for: .seconds(4)) // measurement window
            let after = await viewer.videoStats()
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let frames = after.framesDecoded - before.framesDecoded
            let result = Result(kbps: (after.bytesReceived - before.bytesReceived) * 8 / seconds / 1000,
                                fps: frames / seconds, qp: frames > 0 ? (after.qpSum - before.qpSum) / frames : 0)
            let size = counter.snapshot.1
            var measured = result
            measured.size = size
            results[phase.rawValue] = measured
            print("CHANGING-BYTES config=\(label) phase=\(phase.rawValue) source=\(width)x\(height) \(phase.describe) " +
                "kbit/s=\(String(format: "%.0f", result.kbps)) fps=\(String(format: "%.1f", result.fps)) " +
                "qp=\(String(format: "%.1f", result.qp)) size=\(Int(size.width))x\(Int(size.height))")
            if let line = lines.last("video:") { print("CHANGING-BYTES config=\(label) phase=\(phase.rawValue) host \(line)") }
        }
        return results
    }

    /// The shipped encoding keeps text at full size and spends little on a
    /// small change. Measured on a fleet Mac (#58093): typing 102, pane 163,
    /// full scroll 304 kbit/s at 1280x800. No knob tried (bitrate caps, 30 fps,
    /// balanced or maintain-framerate degradation, a ceiling following the
    /// changed area) spent less beyond run-to-run noise; a camera
    /// (non-screencast) source dropped to 320x200 and spent 4x more on a
    /// scroll. The bounds leave about 2x headroom over those numbers.
    @Test(.timeLimit(.minutes(2)))
    func smallChangesStaySharpAndCheap() async throws {
        let results = try await Self.measure(label: "shipped")
        let typing = try #require(results["typing"]), pane = try #require(results["pane"]), full = try #require(results["full"])
        #expect(typing.kbps < 250, "a typed line costs \(typing.kbps) kbit/s")
        #expect(pane.kbps < 400, "a scrolling pane costs \(pane.kbps) kbit/s")
        #expect(full.kbps < 700, "a full-screen scroll costs \(full.kbps) kbit/s")
        #expect(typing.kbps < full.kbps, "a typed line costs no less than a full scroll")
        #expect(full.fps > 50, "a full scroll runs at \(full.fps) fps")
        for (phase, result) in results {
            #expect(result.size == CGSize(width: 1280, height: 800), "\(phase) arrived at \(result.size): text is no longer sharp")
        }
    }
}

/// The host's log lines (the encoder's own numbers).
final class HostLines: @unchecked Sendable {
    // @unchecked: `lines` is behind `lock`.
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func last(_ prefix: String) -> String? { lock.withLock { lines.last { $0.hasPrefix(prefix) } } }
}

/// A desktop of text-like rows where one part changes at a time (``Phase``),
/// reporting each change's rect as damage, as ScreenCaptureKit does.
final class ChangingScreen: ScreenBackend, ScreenDamageSource, @unchecked Sendable {
    // @unchecked: the timer, `phase` and `index` are touched only on `queue`; `onDamage` is set before start.
    enum Phase: String, Sendable {
        /// Nothing changes.
        case still
        /// A 240×24 line being typed, 10 changes a second.
        case typing
        /// A 640×400 pane (a quarter of the screen) scrolling 4 px a frame at 30 fps.
        case pane
        /// The whole screen scrolling 4 px a frame at 60 fps.
        case full

        var describe: String {
            switch self {
            case .still: "region=none"
            case .typing: "region=240x24@10fps"
            case .pane: "region=640x400@30fps"
            case .full: "region=full@60fps"
            }
        }

        var fps: Int {
            switch self {
            case .still: 0
            case .typing: 10
            case .pane: 30
            case .full: 60
            }
        }
    }

    let width: Int
    let height: Int
    var onDamage: (@Sendable ([CGRect], CGSize) -> Void)?
    private let queue = DispatchQueue(label: "changing-screen")
    private var timer: (any DispatchSourceTimer)?
    private var pool: CVPixelBufferPool?
    private var frame: (@Sendable (CVPixelBuffer, CGRect) -> Void)?
    private var phase = Phase.still
    private var index = 0
    private var paneOffset = 0
    private var fullOffset = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var maximumFrameRate: Int? { 60 }

    /// The pane's rect, and the typed line's.
    var paneRect: CGRect { CGRect(x: width / 4, y: height / 4, width: 640, height: 400) }
    var typingRect: CGRect { CGRect(x: width / 2, y: height - 120, width: 240, height: 24) }

    func set(_ next: Phase) {
        queue.async { [self] in
            phase = next
            timer?.cancel()
            timer = nil
            guard next.fps > 0, frame != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / next.fps))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
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
        displays([CGSize(width: width, height: height)], 0)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        queue.sync {
            pool = created
            self.frame = frame
            if let buffer = render() { frame(buffer, full) }
        }
        set(queue.sync { phase })
    }

    private func tick() {
        let changed: CGRect
        switch phase {
        case .still: return
        case .typing: index += 1; changed = typingRect
        case .pane: paneOffset += 4; changed = paneRect
        case .full: fullOffset += 4; changed = CGRect(x: 0, y: 0, width: width, height: height)
        }
        guard let buffer = render() else { return }
        onDamage?([changed], CGSize(width: width, height: height))
        frame?(buffer, CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Text-like glyph boxes in `x0..<x1` of a row, as text scrolled by `offset`.
    private static func text(_ row: UnsafeMutablePointer<UInt8>, y: Int, x0: Int, x1: Int, offset: Int) {
        let line = (y + offset) / 24, within = (y + offset) % 24
        guard within >= 6, within < 18 else { return }
        var glyph = 0
        var x = x0 + 8
        while x + 7 < x1 {
            // Some glyphs missing (spaces), varying by line: no two lines alike.
            if (line &* 2_654_435_761 &+ glyph &* 40503) % 7 != 0 { memset(row + x, 40, 7) }
            glyph += 1
            x += 10
        }
    }

    private func render() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pane = paneRect, typing = typingRect
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0 ..< height {
                let row = luma + y * stride
                memset(row, 200, width)
                if y >= Int(pane.minY), y < Int(pane.maxY) {
                    Self.text(row, y: y, x0: 0, x1: Int(pane.minX) - 8, offset: fullOffset)
                    memset(row + Int(pane.minX), 230, Int(pane.width))
                    Self.text(row, y: y - Int(pane.minY), x0: Int(pane.minX), x1: Int(pane.maxX), offset: paneOffset)
                    Self.text(row, y: y, x0: Int(pane.maxX) + 8, x1: width, offset: fullOffset)
                } else {
                    Self.text(row, y: y, x0: 0, x1: width, offset: fullOffset)
                }
                if y >= Int(typing.minY), y < Int(typing.maxY) {
                    memset(row + Int(typing.minX), 255, Int(typing.width))
                    if y - Int(typing.minY) >= 6, y - Int(typing.minY) < 18 {
                        for glyph in 0 ..< index % 24 { memset(row + Int(typing.minX) + glyph * 10, 30, 7) }
                    }
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
    func setFrameRate(_ fps: Int) {}

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            frame = nil
        }
    }
}
#endif
