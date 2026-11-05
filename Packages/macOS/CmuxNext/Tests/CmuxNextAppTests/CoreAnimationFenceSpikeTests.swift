import AppKit
import CmuxNextCompat
import CmuxNextTestSupport
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOSurface
import QuartzCore
import ScreenCaptureKit
import Testing

/// SPIKE (scratch/frame-owner-s4-fence-spike-nomerge, never merged; WINDOW-FRAME-SYNC.md, Lead's answer 1): can ONE Core
/// Animation fence port order a main-thread commit (a layer's new bounds) with an off-main commit (its contents at the
/// new size, from a plain thread as Ghostty's GPU-completion thread is), so that both reach the screen in one refresh?
///
/// A borderless window that really draws; ScreenCaptureKit (this process's own windows, no grant) reads every frame the
/// window server composites, with its display time. Each case prints one `FENCE-SPIKE {json}` line.
///
/// Box states, sampled at `inside` (in the old and the new bounds) and `outside` (only in the new bounds):
/// old = green inside, white outside; new = blue at both. Any other frame is bad: the new bounds without the new
/// contents (the stretched old green, or the red background) or blue in the old bounds.
@MainActor @Suite(.serialized, .closesItsWindows,
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct CoreAnimationFenceSpikeTests {
    @Test func probe() throws {
        let scene = try Scene(ownContext: false)
        defer { scene.close() }
        var line = CoreAnimationFence.probe(layer: scene.content).reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        line["case"] = "probe"
        line["window_fence"] = scene.fence != nil
        line["own_context_fence"] = (try? Scene(ownContext: true)).map { other in
            defer { other.close() }
            return other.fence != nil
        } ?? false
        Self.report(line)
    }

    /// The main question: bad frames with and without the fence, the off-main commit at once, after half a refresh
    /// and after three refreshes; the unjoined layer's change (a typed key in a later main commit) and its delay.
    @Test func windowContextFence() async throws {
        try await runCases(ownContext: false, iterations: 50)
    }

    /// The Lead's fix (a): the joined box in its own CAContext (a CALayerHost in the window's tree), the fence made
    /// from that context; the unjoined layer stays in the window's context.
    @Test func ownContextFence() async throws {
        try await runCases(ownContext: true, iterations: 30)
    }

    /// The deadline: the off-main side never commits. The main side releases the port after one refresh, invalidates
    /// the fences after one refresh, or holds the port 2 s (does the system time the fence out?).
    @Test func deadline() async throws {
        let scene = try Scene(ownContext: false)
        defer { scene.close() }
        let recorder = try await scene.startRecording()
        defer { recorder.stop() }
        let gaps = MainGapMeter()
        gaps.start()
        defer { gaps.stop() }
        for (name, iterations) in [("deadline_release_1_refresh", 10), ("deadline_invalidate_1_refresh", 10), ("deadline_hold_2s", 3)] {
            var visibleAfterCommit: [Double] = [], visibleAfterRelease: [Double] = [], unjoined: [Double] = []
            var commitMs: [Double] = []
            gaps.reset()
            for _ in 0..<iterations {
                await scene.reset()
                guard let fence = scene.fence else { break }
                let t0 = Ticks.now
                CATransaction.flush()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let port = fence.createFencePort()
                scene.box.bounds = Scene.newBounds
                scene.box.backgroundColor = Scene.red
                CATransaction.commit()
                commitMs.append(Ticks.ms(t0, Ticks.now))
                let released = Box<UInt64>(0)
                let wait = name == "deadline_hold_2s" ? 2.0 : scene.refresh
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    if name == "deadline_invalidate_1_refresh" { fence.invalidateFences() } else if let port { CoreAnimationFence.release(port) }
                    released.value = Ticks.now
                }
                try await Task.sleep(for: .milliseconds(2))
                let tu = scene.typeUnjoined()
                try await Task.sleep(for: .milliseconds(Int(wait * 1000) + 250))
                if name == "deadline_invalidate_1_refresh", let port { CoreAnimationFence.release(port) }
                let frames = recorder.frames(after: t0)
                if let shown = frames.first(where: { $0.outside != .white }) {
                    visibleAfterCommit.append(Ticks.ms(t0, shown.time))
                    visibleAfterRelease.append(Ticks.ms(released.value, shown.time))
                }
                if let typed = frames.first(where: { $0.unjoined == .yellow }) { unjoined.append(Ticks.ms(tu, typed.time)) }
            }
            Self.report([
                "case": name, "iterations": iterations, "fence": scene.fence != nil, "refresh_ms": scene.refresh * 1000,
                "new_bounds_visible_after_commit_ms": Stats(visibleAfterCommit).json,
                "new_bounds_visible_after_release_ms": Stats(visibleAfterRelease).json,
                "unjoined_delay_ms": Stats(unjoined).json,
                "unjoined_delay_refreshes": Stats(unjoined.map { $0 / (scene.refresh * 1000) }).json,
                "main_commit_ms": Stats(commitMs).json, "max_main_gap_ms": gaps.maxGapMs,
                "capture": recorder.error ?? "screencapturekit",
            ])
        }
    }

    // MARK: - The cases

    private func runCases(ownContext: Bool, iterations: Int) async throws {
        let scene = try Scene(ownContext: ownContext)
        defer { scene.close() }
        try #require(scene.fence != nil, "no fence on this OS (ownContext \(ownContext)): see the probe line")
        let recorder = try await scene.startRecording()
        defer { recorder.stop() }
        await scene.reset()
        let calibration = recorder.frames(after: 0).last
        let calibrated = calibration.map { $0.inside == .green && $0.outside == .white && $0.unjoined == .black } ?? false
        if !calibrated {
            Self.report(["case": ownContext ? "own_context_calibration" : "window_calibration", "ok": false,
                         "last_frame": calibration.map { "\($0.inside)/\($0.outside)/\($0.unjoined)" } ?? "none",
                         "capture": recorder.error ?? "screencapturekit"])
        }
        try #require(calibrated, "the first state did not reach the screen as expected")
        let gaps = MainGapMeter()
        gaps.start()
        defer { gaps.stop() }
        let half = scene.refresh / 2
        for delay in [0, half, scene.refresh * 3] {
            for fenced in [false, true] {
                gaps.reset()
                var result = CaseResult()
                for _ in 0..<iterations {
                    await scene.reset()
                    result.add(try await scene.iteration(fenced: fenced, delay: delay, recorder: recorder))
                }
                var line = result.json(refresh: scene.refresh)
                line["case"] = "\(ownContext ? "own_context" : "window_context")_\(fenced ? "fence" : "control")_delay_\(Int((delay * 1000).rounded()))ms"
                line["own_context"] = ownContext
                line["fence"] = fenced
                line["off_main_delay_ms"] = delay * 1000
                line["iterations"] = iterations
                line["refresh_ms"] = scene.refresh * 1000
                line["max_main_gap_ms"] = gaps.maxGapMs
                line["capture"] = recorder.error ?? "screencapturekit"
                Self.report(line)
            }
        }
    }

    static func report(_ fields: [String: Any]) {
        var fields = fields
        fields["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        fields["host"] = ProcessInfo.processInfo.hostName
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        print("FENCE-SPIKE \(String(decoding: data, as: UTF8.self))")
    }
}

// MARK: - Scene

@MainActor
private final class Scene {
    static let oldBounds = CGRect(x: 0, y: 0, width: 160, height: 160)
    static let newBounds = CGRect(x: 0, y: 0, width: 260, height: 260)
    static let size = CGSize(width: 400, height: 400)
    /// Sample points in the window's content (bottom-left origin). With or without a flipped host they hold: the old box
    /// covers x 20...180 and y 20...180 (or 120...280 flipped), the new one 20...280 both ways.
    static let inside = CGPoint(x: 100, y: 150)
    static let outside = CGPoint(x: 230, y: 150)
    static let unjoinedPoint = CGPoint(x: 350, y: 350)
    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    let window: NSWindow
    let content: CALayer
    let box: CALayer
    let unjoined: CALayer
    let hosted: CoreAnimationHostedContext?
    let fence: CoreAnimationFence?
    let refresh: Double
    let green: IOSurfaceRef
    let blue: IOSurfaceRef

    init(ownContext: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 120, y: 120), size: Self.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        window.contentView = view
        let content = view.layer ?? CALayer()
        content.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let scale = window.backingScaleFactor
        let green = Self.surface(Self.oldBounds.size, scale: scale, bgra: (0, 255, 0))
        let blue = Self.surface(Self.newBounds.size, scale: scale, bgra: (255, 0, 0))
        let box = CALayer()
        box.anchorPoint = .zero
        box.contentsGravity = .resize
        box.bounds = Self.oldBounds
        box.contents = green
        box.backgroundColor = Self.red
        let unjoined = CALayer()
        unjoined.anchorPoint = .zero
        unjoined.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        unjoined.position = CGPoint(x: 320, y: 320)
        unjoined.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        content.addSublayer(unjoined)
        window.orderFrontRegardless()
        var hosted: CoreAnimationHostedContext?
        let fence: CoreAnimationFence?
        if ownContext {
            box.position = .zero
            hosted = CoreAnimationHostedContext(root: box)
            if let host = hosted?.hostLayer {
                host.anchorPoint = .zero
                host.frame = CGRect(x: 20, y: 20, width: 260, height: 260)
                content.addSublayer(host)
            }
            fence = hosted?.fence
        } else {
            box.position = CGPoint(x: 20, y: 20)
            content.addSublayer(box)
            CATransaction.flush()
            fence = CoreAnimationFence(contextOf: content)
        }
        CATransaction.flush()
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        self.window = window
        self.content = content
        self.box = box
        self.unjoined = unjoined
        self.hosted = hosted
        self.fence = fence
        self.green = green
        self.blue = blue
        refresh = 1 / Double(fps > 0 ? fps : 60)
    }

    func close() {
        window.close()
    }

    func startRecording() async throws -> FrameRecorder {
        let points = [Self.inside, Self.outside, Self.unjoinedPoint].map { CGPoint(x: $0.x, y: Self.size.height - $0.y) }
        let recorder = FrameRecorder(points: points, size: Self.size)
        try await recorder.start(windowID: CGWindowID(window.windowNumber))
        return recorder
    }

    /// The old state, committed, then 120 ms for it to reach the screen.
    func reset() async {
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.bounds = Self.oldBounds
        box.contents = green
        unjoined.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        CATransaction.commit()
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// The unjoined layer's change in its own main commit (a typed key); returns when it committed.
    func typeUnjoined() -> UInt64 {
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unjoined.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        CATransaction.commit()
        return Ticks.now
    }

    /// Main: the new bounds (and red) with the fence; off main (a plain thread) after `delay`: blue at the new size,
    /// joined to the fence, then the port released. 2 ms after the main commit, the unjoined change.
    func iteration(fenced: Bool, delay: Double, recorder: FrameRecorder) async throws -> Iteration {
        let t0 = Ticks.now
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let port = fenced ? fence?.createFencePort() : nil
        box.bounds = Self.newBounds
        box.backgroundColor = Self.red
        CATransaction.commit()
        let mainCommitMs = Ticks.ms(t0, Ticks.now)
        let released = Box<UInt64>(0)
        let offMain = Box<(box: CALayer, blue: IOSurfaceRef, fence: CoreAnimationFence?)>((box, blue, fence))
        let thread = Thread {
            if delay > 0 { usleep(UInt32(delay * 1_000_000)) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let port { offMain.value.fence?.join(port) }
            offMain.value.box.contents = offMain.value.blue
            CATransaction.commit()
            if let port { CoreAnimationFence.release(port) }
            released.value = Ticks.now
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        try await Task.sleep(for: .milliseconds(2))
        let typedAt = typeUnjoined()
        try await Task.sleep(for: .milliseconds(Int(delay * 1000) + 250))
        return Iteration(frames: recorder.frames(after: t0), t0: t0, typedAt: typedAt, releasedAt: released.value,
                         mainCommitMs: mainCommitMs, fenced: port != nil)
    }

    static func surface(_ size: CGSize, scale: CGFloat, bgra: (UInt8, UInt8, UInt8)) -> IOSurfaceRef {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                           kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
        let surface = IOSurfaceCreate(properties as CFDictionary)!
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let row = IOSurfaceGetBytesPerRow(surface)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * row + x * 4
                pixel[0] = bgra.0; pixel[1] = bgra.1; pixel[2] = bgra.2; pixel[3] = 255
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
}

// MARK: - Analysis

private nonisolated struct Iteration {
    let frames: [Frame]
    let t0: UInt64
    let typedAt: UInt64
    let releasedAt: UInt64
    let mainCommitMs: Double
    let fenced: Bool
}

private nonisolated struct CaseResult {
    var frames = 0
    var badFrames = 0
    var badIterations = 0
    var badKinds: [String: Int] = [:]
    var firstNewMs: [Double] = []
    var unjoinedMs: [Double] = []
    var unjoinedHeld = 0
    var unjoinedHeldMs: [Double] = []
    var mainCommitMs: [Double] = []
    var noNewFrame = 0

    mutating func add(_ it: Iteration) {
        mainCommitMs.append(it.mainCommitMs)
        var bad = 0
        for frame in it.frames {
            frames += 1
            switch (frame.inside, frame.outside) {
            case (.green, .white), (.blue, .blue): continue
            case (_, .green): badKinds["new_bounds_old_contents_stretched", default: 0] += 1
            case (_, .red): badKinds["new_bounds_no_contents", default: 0] += 1
            case (.blue, .white): badKinds["new_contents_old_bounds", default: 0] += 1
            default: badKinds["other_\(frame.inside)_\(frame.outside)", default: 0] += 1
            }
            bad += 1
        }
        badFrames += bad
        if bad > 0 { badIterations += 1 }
        let firstNew = it.frames.first { $0.inside == .blue && $0.outside == .blue }
        if let firstNew { firstNewMs.append(Ticks.ms(it.t0, firstNew.time)) } else { noNewFrame += 1 }
        if let typed = it.frames.first(where: { $0.unjoined == .yellow }) {
            let delay = Ticks.ms(it.typedAt, typed.time)
            unjoinedMs.append(delay)
            // Held: it showed only with or after the fenced frame, though the port went more than a refresh after it.
            if it.fenced, let firstNew, typed.time >= firstNew.time, it.releasedAt > it.typedAt {
                unjoinedHeld += 1
                unjoinedHeldMs.append(delay)
            }
        }
    }

    func json(refresh: Double) -> [String: Any] {
        [
            "frames": frames, "bad_frames": badFrames, "bad_iterations": badIterations, "bad_kinds": badKinds,
            "first_new_frame_after_main_commit_ms": Stats(firstNewMs).json, "iterations_without_new_frame": noNewFrame,
            "unjoined_delay_ms": Stats(unjoinedMs).json,
            "unjoined_delay_refreshes": Stats(unjoinedMs.map { $0 / (refresh * 1000) }).json,
            "unjoined_held": unjoinedHeld, "unjoined_held_delay_ms": Stats(unjoinedHeldMs).json,
            "main_commit_ms": Stats(mainCommitMs).json,
        ]
    }
}

private nonisolated struct Stats {
    let values: [Double]
    init(_ values: [Double]) { self.values = values.sorted() }
    var json: [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        func at(_ q: Double) -> Double { (values[min(values.count - 1, Int(Double(values.count - 1) * q))] * 100).rounded() / 100 }
        return ["n": values.count, "min": at(0), "p50": at(0.5), "p95": at(0.95), "max": at(1)]
    }
}

private nonisolated final class Box<Value>: @unchecked Sendable {
    // concurrency-allow: spike; one writer thread, read by main after a 250 ms sleep that follows the write.
    var value: Value
    init(_ value: Value) { self.value = value }
}

private nonisolated enum Ticks {
    static let ticksPerMs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e6 * Double(info.denom) / Double(info.numer)
    }()
    static var now: UInt64 { mach_absolute_time() }
    static func ms(_ from: UInt64, _ to: UInt64) -> Double { (Double(to) - Double(from)) / ticksPerMs }
}

/// Main-queue ticks every millisecond; the largest gap between two is how long the main thread was away.
@MainActor
private final class MainGapMeter {
    private var timer: (any DispatchSourceTimer)?
    private var last: UInt64 = 0
    private(set) var maxGap: UInt64 = 0
    var maxGapMs: Double { (Double(maxGap) / Ticks.ticksPerMs * 100).rounded() / 100 }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Ticks.now
                if self.last != 0 { self.maxGap = max(self.maxGap, now - self.last) }
                self.last = now
            }
        }
        timer.resume()
        self.timer = timer
    }

    func reset() {
        last = 0
        maxGap = 0
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Capture

private nonisolated enum Color: String, CustomStringConvertible {
    case white, red, green, blue, yellow, black
    var description: String { rawValue }

    static func nearest(r: Double, g: Double, b: Double) -> Color {
        let palette: [(Color, Double, Double, Double)] = [(.white, 255, 255, 255), (.red, 255, 0, 0), (.green, 0, 255, 0),
                                                         (.blue, 0, 0, 255), (.yellow, 255, 255, 0), (.black, 0, 0, 0)]
        return palette.min { lhs, rhs in
            func d(_ c: (Color, Double, Double, Double)) -> Double { pow(c.1 - r, 2) + pow(c.2 - g, 2) + pow(c.3 - b, 2) }
            return d(lhs) < d(rhs)
        }!.0
    }
}

private nonisolated struct Frame {
    let time: UInt64
    let inside: Color
    let outside: Color
    let unjoined: Color
}

/// A ScreenCaptureKit stream of the window alone; each complete frame sampled at three points on its own queue.
private nonisolated final class FrameRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let points: [CGPoint]
    private let size: CGSize
    private let queue = DispatchQueue(label: "fence-spike.capture", qos: .userInteractive)
    // concurrency-allow: spike; appended on the capture queue, copied out on main.
    private let collected = Mutex<[Frame]>([])
    private var stream: SCStream?
    private(set) var error: String?

    init(points: [CGPoint], size: CGSize) {
        self.points = points
        self.size = size
    }

    func start(windowID: CGWindowID) async throws {
        guard #available(macOS 14.4, *) else { throw SpikeError("ScreenCaptureKit current-process content needs macOS 14.4") }
        var target: SCWindow?
        for _ in 0..<20 {
            let content = try await SCShareableContent.currentProcess
            target = content.windows.first { $0.windowID == windowID }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target else { throw SpikeError("ScreenCaptureKit lists no window \(windowID)") }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        try await Task.sleep(for: .milliseconds(300))
    }

    func stop() {
        let stream = self.stream
        Task { try? await stream?.stopCapture() }
    }

    func frames(after time: UInt64) -> [Frame] {
        collected.withLock { frames in
            frames.filter { $0.time > time }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = (info[.displayTime] as? NSNumber)?.uint64Value ?? Ticks.now
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let colors = points.map { point -> Color in
            let x = min(width - 1, Int(point.x * Double(width) / size.width))
            let y = min(height - 1, Int(point.y * Double(height) / size.height))
            let p = base + y * row + x * 4
            return Color.nearest(r: Double(p[2]), g: Double(p[1]), b: Double(p[0]))
        }
        collected.withLock { $0.append(Frame(time: time, inside: colors[0], outside: colors[1], unjoined: colors[2])) }
    }
}

private nonisolated struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// SPIKE, headless: which fence SPI selectors and classes this OS has (no window, no display). Runs on any worker, so
/// a macOS 26 mini without a GUI session (aws-m4pro-5..9) still answers the selector question.
@MainActor @Suite
struct CoreAnimationFenceProbeTests {
    @Test func selectorsOnThisOS() {
        var line = CoreAnimationFence.probe(layer: nil).reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        line["case"] = "probe_headless"
        let root = CALayer()
        line["own_context_made_headless"] = CoreAnimationHostedContext(root: root) != nil
        CoreAnimationFenceSpikeTests.report(line)
    }
}
