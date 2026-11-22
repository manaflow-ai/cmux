#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import CmuxNextCompat
import CmuxNextWakeups
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

/// How a frame strip read its frames (``FrameStripRecording``).
public nonisolated enum WindowFrameCapture: String, Sendable {
    /// ScreenCaptureKit with this process's own shareable content: no Screen Recording grant needed, and the
    /// Chromium pages (drawn by the GPU process) are in the frames.
    case screenCaptureKit = "screencapturekit"
    /// `CGWindowListCreateImage` back to back (``WindowFrame/recordAbove(_:bounds:scale:from:until:)``,
    /// ``WindowFrame/record(_:scale:crop:from:until:)``). Without the Screen Recording grant the window server leaves
    /// out what another process draws: a Chromium page comes out as its background.
    case windowList = "window_list"
}

/// One frame strip's recording (`debug.new_tab {action: "frame_strip"}`), started at `start`: the window's composited
/// image (`crop`), or with `above` the screen in that rect, this app's windows over the window (its Chromium pages)
/// included.
///
/// `above` without the Screen Recording grant (a fleet step's app answers to the build worker, which has none, and
/// macOS keeps SIP on) reads ScreenCaptureKit's current-process content (macOS 14.4+, no grant): the display showing
/// only this app's windows, cut to `above`, every frame the window server composites. The window list there leaves
/// the Chromium page out of every frame, so a strip over a chat measured a blank pane (cmuxterm-hq#6338). With the
/// grant, with `capture: "window_list"`, or when ScreenCaptureKit fails (`capture_error`), the window list as before.
///
/// ScreenCaptureKit takes a moment to give its first frame: ``waitForLead()`` waits for it as well as the `lead`, and
/// the recording ends as much later, so `duration` ms after the key stay recorded.
public nonisolated final class FrameStripRecording: Sendable {
    public typealias Recorded = (frames: [WindowFrame], capture: WindowFrameCapture, error: String?)
    private let lead: Double
    private let firstFrame = FrameSignal()
    /// `stream`: what a ScreenCaptureKit stream gave, buffer by buffer (none for the window list).
    private let task: Task<(recorded: Recorded, stream: StreamTally?), Never>

    public init(_ window: CGWindowID, above: CGRect?, crop: CGRect?, scale: Double, from start: ContinuousClock.Instant,
                lead: Double, duration: Double, capture: String?) {
        self.lead = lead
        let first = firstFrame
        let until = lead + duration
        let asked = capture.flatMap(WindowFrameCapture.init(rawValue:))
        task = Task.detached(priority: .userInitiated) {
            defer { first.fire() }
            guard let above else {
                first.fire()
                return ((await WindowFrame.record(window, scale: scale, crop: crop, from: start, until: until), .windowList, nil), nil)
            }
            var failure: String?
            if (asked ?? (CGPreflightScreenCaptureAccess() ? .windowList : .screenCaptureKit)) == .screenCaptureKit {
                if #available(macOS 14.4, *) {
                    do {
                        let stream = ScreenFrameStream(window: window, bounds: above, scale: scale, start: start, first: first)
                        let frames = try await stream.run(lead: lead, until: until)
                        if !frames.isEmpty { return ((frames, .screenCaptureKit, nil), stream.tally()) }
                        failure = "ScreenCaptureKit gave no frame"
                    } catch {
                        failure = "\(error)"
                    }
                } else {
                    failure = "own-window ScreenCaptureKit needs macOS 14.4"
                }
            }
            // A failed stream took time: the window list still records `duration` ms after the key that follows.
            let end = max(until, WindowFrame.elapsed(since: start) + duration)
            first.fire()
            return ((await WindowFrame.recordAbove(window, bounds: above, scale: scale, from: start, until: end), .windowList, failure), nil)
        }
    }

    /// Returns `lead` ms after the start, or once the first frame is in when that is later: a key sent then has a
    /// frame from before it.
    public func waitForLead() async {
        await FrameSignal.pause(milliseconds: lead, owner: "debug.frame_strip.lead")
        await firstFrame.untilFired()
    }

    /// The frames, and the report's fields about them: `capture`, `capture_error`, `lead_ms` (`sentAt`, when the
    /// key went in, ms after the start), and for a ScreenCaptureKit recording `screen_stream` (``StreamTally``).
    public func result(sentAt: Double) async -> (frames: [WindowFrame], fields: [String: any Sendable]) {
        let (result, stream) = await task.value
        var fields: [String: any Sendable] = ["capture": result.capture.rawValue, "lead_ms": sentAt.rounded()]
        if let error = result.error { fields["capture_error"] = error }
        if let stream { fields["screen_stream"] = stream.fields(sentAt: sentAt) }
        return (result.frames, fields)
    }
}

/// What one ScreenCaptureKit stream gave, buffer by buffer: the reply's `screen_stream`, numbers and status letters
/// only. A frame of the display with no row in a frame strip has one of three causes, and these counts tell them
/// apart: a buffer that made no row (`no_row`: another status than complete or idle, or a picture that did not
/// copy), a row whose time is the handler's own and not the display's (`own_time_rows`), or no buffer at all.
nonisolated struct StreamTally: Sendable {
    /// Why a buffer made no row, where that is not its status's raw number.
    static let noStatus = -1, noPicture = -2, idleBeforeAPicture = -3

    /// Where a row's time comes from: the buffer's display time (`age` ms before the handler ran), or the handler's
    /// own time (the buffer has no display time, or one later than the handler's).
    nonisolated enum Time: Sendable {
        case display(age: Double)
        case missing
        case later
    }

    private var rowStatus = ""
    private var rowTimes: [Double] = []
    private var ownTimeRows: [Int] = []
    private var noRows: [(at: Double, why: Int)] = []
    private var noRowCounts: [Int: Int] = [:]
    private var complete = 0
    private var idle = 0
    private var noDisplayTime = 0
    private var displayTimeLater = 0
    private var lagMax = 0.0
    private var lagSum = 0.0
    private var lagCount = 0
    private var workMax = 0.0
    private var workSum = 0.0

    /// A buffer that made the row `index` (its place in the frames, which is the number of its file), `at` ms after
    /// the start. `status`: `c` a complete buffer's picture, `i` an idle buffer's repeat of the last picture.
    /// `work`: the handler's ms for it.
    mutating func row(_ status: Character, index: Int, at: Double, time: Time, work: Double) {
        rowStatus.append(status)
        rowTimes.append(at)
        if status == "c" {
            complete += 1
            workMax = max(workMax, work)
            workSum += work
        } else {
            idle += 1
        }
        switch time {
        case let .display(age):
            lagMax = max(lagMax, age)
            lagSum += age
            lagCount += 1
        case .missing:
            noDisplayTime += 1
            ownTimeRows.append(index)
        case .later:
            displayTimeLater += 1
            ownTimeRows.append(index)
        }
    }

    /// A buffer that made no row, `at` ms after the start. `why`: its status's raw number, or one of the three above.
    /// The first 256 keep their time.
    mutating func noRow(at: Double, why: Int) {
        noRowCounts[why, default: 0] += 1
        if noRows.count < 256 { noRows.append((at, why)) }
    }

    /// The reply's `screen_stream`. `sentAt`: when the key went in, ms after the start; `no_row` and `row_ms` (each
    /// row's time, in tenths of a ms where the row's own `ms` is a whole one) count from it.
    func fields(sentAt: Double) -> [String: any Sendable] {
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        let noStatus = noRowCounts[Self.noStatus] ?? 0
        let noPicture = noRowCounts[Self.noPicture] ?? 0
        let idleBeforeAPicture = noRowCounts[Self.idleBeforeAPicture] ?? 0
        var otherStatus: [String: Int] = [:]
        for (why, count) in noRowCounts where why >= 0 { otherStatus[String(why)] = count }
        let buffers = rowStatus.count + noRowCounts.values.reduce(0, +)
        let noRowTimes: [[Double]] = noRows.map { [tenth($0.at - sentAt), Double($0.why)] }
        let rowMs: [Double] = rowTimes.map { tenth($0 - sentAt) }
        let lagMean = lagCount > 0 ? lagSum / Double(lagCount) : 0
        let workMean = complete > 0 ? workSum / Double(complete) : 0
        var fields: [String: any Sendable] = ["buffers": buffers, "rows": rowStatus.count, "row_status": rowStatus]
        fields["complete"] = complete + noPicture
        fields["idle"] = idle + idleBeforeAPicture
        fields["other_status"] = otherStatus
        fields["no_status"] = noStatus
        fields["no_picture"] = noPicture
        fields["idle_before_a_picture"] = idleBeforeAPicture
        fields["own_time_rows"] = ownTimeRows
        fields["no_display_time"] = noDisplayTime
        fields["display_time_later"] = displayTimeLater
        fields["no_row"] = noRowTimes
        fields["row_ms"] = rowMs
        fields["lag_ms_max"] = tenth(lagMax)
        fields["lag_ms_mean"] = tenth(lagMean)
        fields["work_ms_max"] = tenth(workMax)
        fields["work_ms_mean"] = tenth(workMean)
        return fields
    }
}

/// Fires once; ``untilFired()`` returns at once after that. Any thread.
nonisolated final class FrameSignal: Sendable {
    // concurrency-allow: held only to read or set the flag and take the waiters; resuming them happens after the unlock.
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.fired else { return [] }
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func untilFired() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.fired { return true }
                state.waiters.append(done)
                return false
            }
            if now { done.resume() }
        }
    }

    /// Returns when this fires or after `milliseconds`, whichever comes first.
    func untilFired(orAfter milliseconds: Double, owner: String) async {
        let timer = DemandTimer(owner: owner)
        defer { timer.cancel() }
        timer.schedule(after: .milliseconds(Int(max(0, milliseconds).rounded(.up)))) { [self] in fire() }
        await untilFired()
    }

    /// Returns after `milliseconds` (a demand timer; at once for none).
    static func pause(milliseconds: Double, owner: String) async {
        guard milliseconds > 0 else { return }
        await FrameSignal().untilFired(orAfter: milliseconds, owner: owner)
    }
}

/// One ScreenCaptureKit stream of this app's windows in a rect, collected as ``WindowFrame``s on its own queue (no
/// main-thread work per frame). An idle frame (nothing changed on screen) repeats the last picture at its time, so
/// a still picture keeps counting frames as the window list's back-to-back reads did.
@available(macOS 14.4, *)
nonisolated final class ScreenFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let window: CGWindowID
    private let bounds: CGRect
    private let scale: Double
    private let start: ContinuousClock.Instant
    /// Fired at the first frame (the strip's key waits for it).
    private let first: FrameSignal
    /// Fired at the first frame or a stop: the end waits for it, at most 3 s past `until`.
    private let started = FrameSignal()
    private let queue = DispatchQueue(label: "debug.frame_strip.screen", qos: .userInitiated)
    nonisolated struct Collected: Sendable {
        var frames: [WindowFrame] = []
        var last: WindowFrame?
        /// When the first frame came, ms after `start`.
        var firstAt: Double?
        /// What the stream gave, buffer by buffer: one `row` for each of `frames`, one `noRow` for each other buffer.
        var tally = StreamTally()
    }

    // concurrency-allow: written by the sample handler on `queue`, read after a hop onto it; held only to append or copy.
    private let collected = Mutex(Collected())
    // concurrency-allow: held only to set or read the stop error; no call out runs under it.
    private let stopped = Mutex<String?>(nil)

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(window: CGWindowID, bounds: CGRect, scale: Double, start: ContinuousClock.Instant, first: FrameSignal) {
        self.window = window
        self.bounds = bounds
        self.scale = scale
        self.start = start
        self.first = first
    }

    /// Starts the stream, keeps it until `until` ms after `start` (later by as much as the first frame came after
    /// `lead`), stops it and returns the frames.
    func run(lead: Double, until: Double) async throws -> [WindowFrame] {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == window }) else {
            throw Failure(description: "ScreenCaptureKit lists no window \(window) of this process")
        }
        guard let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.displays.first else {
            throw Failure(description: "ScreenCaptureKit lists no display for this process")
        }
        // Every on-screen window of this app on that display: the Chromium page windows and the panels over the window.
        // Never a window only the person may see (CaptureExcludedWindows: the join consent ask).
        let excluded = CaptureExcludedWindows().windowIDs
        let own = content.windows.filter { $0.isOnScreen && $0.frame.intersects(display.frame) && !excluded.contains($0.windowID) }
        let filter = SCContentFilter(display: display, including: own.isEmpty ? [target] : own)
        let configuration = SCStreamConfiguration()
        // Points, as the window list's nominal-resolution image: frames compare the same and WindowFrame scales them.
        configuration.sourceRect = bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(2, Int(bounds.width.rounded()))
        configuration.height = max(2, Int(bounds.height.rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240) // faster than any display: every composited frame
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.scalesToFit = false
        configuration.backgroundColor = CGColor.clear
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        await started.untilFired(orAfter: until + 3_000 - WindowFrame.elapsed(since: start), owner: "debug.frame_strip.first")
        let firstMs = collected.withLock { $0.firstAt }
        let end = firstMs.map { until + max(0, $0 - lead) } ?? until + 3_000
        await FrameSignal.pause(milliseconds: end - WindowFrame.elapsed(since: start), owner: "debug.frame_strip.end")
        try? await stream.stopCapture()
        // The handler runs on `queue`: one hop after the stop has every frame it delivered.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        let frames = collected.withLock { $0.frames }
        if frames.isEmpty, let reason = stopped.withLock({ $0 }) { throw Failure(description: reason) }
        return frames
    }

    /// What the stream gave (the reply's `screen_stream`), once ``run(lead:until:)`` has returned.
    func tally() -> StreamTally {
        collected.withLock { $0.tally }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int else {
            let at = WindowFrame.elapsed(since: start)
            collected.withLock { $0.tally.noRow(at: at, why: StreamTally.noStatus) }
            return
        }
        // The frame's display time, as ms after `start`: its age now, taken from the elapsed time now. A buffer with
        // no display time, or with a later one, has the handler's own time: the tally says which rows those are.
        let now = mach_absolute_time()
        let display = (info[.displayTime] as? NSNumber)?.uint64Value
        let shown = min(display ?? now, now)
        let age = Double(now - shown) * Self.secondsPerTick * 1000
        let at = WindowFrame.elapsed(since: start) - age
        let time = display.map { value -> StreamTally.Time in value > now ? .later : .display(age: age) } ?? .missing
        switch SCFrameStatus(rawValue: raw) {
        case .complete?:
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let image = Self.image(of: buffer),
                  let frame = WindowFrame(image, scale: scale, at: at) else {
                collected.withLock { $0.tally.noRow(at: at, why: StreamTally.noPicture) }
                return
            }
            let arrived = WindowFrame.elapsed(since: start)
            let isFirst = collected.withLock { state -> Bool in
                state.tally.row("c", index: state.frames.count, at: at, time: time, work: arrived - at - age)
                state.frames.append(frame)
                state.last = frame
                guard state.firstAt == nil else { return false }
                state.firstAt = arrived
                return true
            }
            if isFirst {
                first.fire()
                started.fire()
            }
        case .idle?:
            collected.withLock { state in
                guard var again = state.last else {
                    state.tally.noRow(at: at, why: StreamTally.idleBeforeAPicture)
                    return
                }
                again.milliseconds = at
                state.tally.row("i", index: state.frames.count, at: at, time: time, work: 0)
                state.frames.append(again)
            }
        default:
            collected.withLock { $0.tally.noRow(at: at, why: raw) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopped.withLock { $0 = String(describing: error) }
        started.fire()
    }

    /// A copy of a BGRA pixel buffer as an image.
    private static func image(of buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return context.makeImage()
    }
}
#endif
