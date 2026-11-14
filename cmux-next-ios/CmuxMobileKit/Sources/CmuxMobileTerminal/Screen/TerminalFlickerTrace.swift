#if os(iOS) && DEBUG
import CmuxMobileSupport
import QuartzCore
import UIKit

/// DEBUG only. `-CmuxMobileTerminalFlickerTrace`: what the terminal page
/// draws on every display frame while the keyboard shows and hides
/// (TerminalKeyboardToggleFlickerUITests), from presentation layers, one line
/// per frame to `Documents/terminal-flicker-trace.txt`, and counts on the
/// `debug.terminal-flicker` probe.
///
/// Counted from the demo's first toggle (`show0`) to its end (`done.`):
/// - `jump`: frames where the rows on screen are not where they belong, two
///   or more frames in a row (`jump1`: single frames, see `measure`). A
///   full-screen app's grid ends on the composer stack's top (`pin`, its
///   bottom edge minus the stack's top, against the value at rest); a
///   shell's last row keeps its gap above the stack (`gap`). A held frame
///   (the still over a mirror reset) is what was on screen and counts as
///   placed.
/// - `blank`: frames with nothing legible: a full-screen app's grid with no
///   text, or a shell page showing background where it has rows.
/// - `note`: frames that show the letterbox note ("53×25 · set by …").
/// - `late`: frames where a full-screen app's grid is still not the area's
///   (a band above it, or its top rows under the toolbar) though the
///   composer has stopped for two frames.
/// - `drift`: a shell's last row a row or more off its gap to the composer,
///   two or more frames in a row.
/// - `band`: frames where a full-screen app's grid leaves more than a row
///   of background between the toolbar and its first row (informational:
///   the keyboard hiding over a grid the Mac has not grown yet).
/// - `snap`: frames where the rows moved while the composer stood still.
/// - `rev`: frames where a shell's rows moved against the keyboard.
/// - `sized`: frames where the surface changed size.
/// - `hitch1`/`hitch2`: frame intervals of two, and of three or more, frames.
/// - `rz`: PTY resizes sent per demo step.
@MainActor
final class TerminalFlickerTrace: NSObject {
    static let flag = "-CmuxMobileTerminalFlickerTrace"
    static var isRequested: Bool { CommandLine.arguments.contains(flag) }
    static let traceURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("terminal-flicker-trace.txt")

    /// One frame of the page, view coordinates, as drawn.
    struct Sample {
        var demo: String
        var isTUI: Bool
        var held: Bool
        var stackTop: CGFloat
        var resizes: Int
        var surfaceSize: CGSize
        // Full-screen app.
        var gridTop: CGFloat = 0
        var gridRows = 0
        var clipTop: CGFloat = 0
        var cellHeight: CGFloat = 0
        var noteShown = false
        var nonBlankRows = 0
        // Shell.
        var contentBottom: CGFloat = 0
        var legibleBlank = false
        /// The scroll view's offset (model, as drawn), bottom inset, and the
        /// surface's top and bottom as drawn, in the page's points.
        var offsetModel: CGFloat = 0
        var offsetDrawn: CGFloat = 0
        var insetBottom: CGFloat = 0
        var surfaceTop: CGFloat = 0
        var surfaceBottom: CGFloat = 0
        var following = false
    }

    private let sample: () -> Sample?
    private var link: CADisplayLink?
    /// The page as Core Animation last committed it (read after the run
    /// loop's commit): the frame a display refresh shows. Read on the
    /// display link itself, the page's own display links (output, present)
    /// may have changed it in the same refresh, uncommitted, and a held
    /// frame let go together with the new grid read as one frame without
    /// either.
    private var committed: Sample?
    private var observer: CFRunLoopObserver?
    private let handle: FileHandle?
    private let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let start = CACurrentMediaTime()
    /// Main-thread time per frame: all of it, and the page's own measured work.
    private let busyMeter = MainThreadBusyMeter()
    private var ours: [String: Double] = [:]

    /// The page's measured work (`TerminalViewController.measured`), by name.
    func work(_ name: String, _ seconds: CFTimeInterval) {
        ours[name, default: 0] += seconds * 1000
    }
    private weak var host: UIView?

    private var measuring = false
    private var finished = false
    private var reference: CGFloat?
    private var previous: Sample?
    private var lastTimestamp: CFTimeInterval = 0
    private var stepResizes: [String] = []
    private var stepStartResizes = 0
    private var step = ""
    private var counts: [String: Int] = [:]
    private var largestJump: CGFloat = 0
    /// Consecutive frames off their place so far.
    private var jumpRun = 0
    /// Consecutive frames a shell's last row was a row or more off its gap.
    private var driftRun = 0
    /// Consecutive frames the composer stack has not moved.
    private var stackStill = 0
    /// The last frame's placement value (pin or gap).
    private var previousValue: CGFloat = 0
    private var jumpLog: [String] = []

    init(host: UIView, sample: @escaping () -> Sample?) {
        self.sample = sample
        self.host = host
        let url = Self.traceURL
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        super.init()
        probe.isUserInteractionEnabled = false
        probe.alpha = 0.02
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "debug.terminal-flicker"
        probe.accessibilityLabel = "terminal flicker probe"
        let link = CADisplayLink(target: WeakTick(self), selector: #selector(WeakTick.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // After Core Animation's commit observer (order 2_000_000).
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.committed = self?.sample() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    isolated deinit {
        stop()
    }

    func stop() {
        busyMeter.stop()
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func count(_ key: String) { counts[key, default: 0] += 1 }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let host else { return stop() }
        guard let window = host.window else { return }
        if probe.window !== window { window.addSubview(probe) }
        guard let now = committed ?? sample() else { return }
        let t = link.timestamp - start
        let duration = max(1.0 / 120, link.targetTimestamp - link.timestamp)
        let interval = lastTimestamp > 0 ? link.timestamp - lastTimestamp : 0
        lastTimestamp = link.timestamp

        if !measuring, !finished, now.demo.hasPrefix("show0") {
            measuring = true
            stepStartResizes = now.resizes
            step = now.demo
        }
        var line = String(format: "t=%.4f demo=%@ tui=%d held=%d stack=%.2f rz=%d dt=%.4f", t, now.demo, now.isTUI ? 1 : 0,
                          now.held ? 1 : 0, now.stackTop, now.resizes, interval)
        if now.isTUI {
            let pin = now.gridTop + CGFloat(now.gridRows) * now.cellHeight - now.stackTop
            line += String(format: " grid=%.2f rows=%d clip=%.2f pin=%.2f note=%d nb=%d", now.gridTop, now.gridRows, now.clipTop, pin,
                           now.noteShown ? 1 : 0, now.nonBlankRows)
        } else {
            line += String(format: " cb=%.2f gap=%.2f blank=%d off=%.2f offd=%.2f inb=%.2f sft=%.2f sfb=%.2f fol=%d", now.contentBottom,
                           now.stackTop - now.contentBottom, now.legibleBlank ? 1 : 0, now.offsetModel, now.offsetDrawn, now.insetBottom,
                           now.surfaceTop, now.surfaceBottom, now.following ? 1 : 0)
        }
        if measuring { measure(now, t: t, interval: interval, duration: duration) }
        if measuring, now.demo.hasPrefix("done.") {
            measuring = false
            finished = true
            stepResizes.append("\(step):\(now.resizes - stepStartResizes)")
        }
        let busy = busyMeter.take()
        line += String(format: " busy=%.1f span=%.1f ours=%.1f", busy.busyMs, busy.longestMs, ours.values.reduce(0, +))
        if !ours.isEmpty {
            line += " parts=" + ours.sorted { $0.value > $1.value }.prefix(4).map { String(format: "%@:%.1f", $0.key, $0.value) }.joined(separator: ",")
        }
        ours.removeAll(keepingCapacity: true)
        handle?.write(Data((line + "\n").utf8))
        previous = now
        probe.accessibilityValue = summary(demo: now.demo)
    }

    private func measure(_ now: Sample, t: CFTimeInterval, interval: CFTimeInterval, duration: CFTimeInterval) {
        count("frames")
        if now.demo != step {
            stepResizes.append("\(step):\(now.resizes - stepStartResizes)")
            stepStartResizes = now.resizes
            step = now.demo
        }
        if interval > duration * 2.5 { count("hitch2") } else if interval > duration * 1.5 { count("hitch1") }
        if let previous, previous.surfaceSize != now.surfaceSize { count("sized") }
        let value: CGFloat
        if now.isTUI {
            value = now.gridTop + CGFloat(now.gridRows) * now.cellHeight - now.stackTop
            if !now.held, now.noteShown { count("note") }
            if !now.held, now.nonBlankRows == 0 { count("blank") }
            if !now.held, now.gridTop - now.clipTop > now.cellHeight { count("band") }
        } else {
            value = now.stackTop - now.contentBottom
            if now.legibleBlank { count("blank") }
        }
        let reference = reference ?? value
        self.reference = reference
        if let previous { stackStill = abs(now.stackTop - previous.stackTop) < 0.1 ? stackStill + 1 : 0 }
        if now.isTUI, stackStill >= 2, !now.held,
           now.gridTop - now.clipTop > now.cellHeight || now.clipTop - now.gridTop > 1 {
            // The keyboard has stopped and the grid is still not the area's:
            // a band above it, or its top rows under the toolbar.
            count("late")
        }
        if !now.isTUI, now.cellHeight > 0 {
            if abs(value - reference) > now.cellHeight {
                driftRun += 1
                if driftRun == 2 { counts["drift", default: 0] += 2 } else if driftRun > 2 { count("drift") }
            } else {
                driftRun = 0
            }
        }
        if !now.held, abs(value - reference) > 1 {
            jumpRun += 1
            // A reading one frame long can be an intermediate commit the
            // display never showed (the page commits more than once a frame);
            // `jump` counts frames from the second in a row on, `jump1` the
            // single ones (checked against the video's frame splits).
            switch jumpRun {
            case 1: count("jump1")
            case 2:
                counts["jump1", default: 0] -= 1
                counts["jump", default: 0] += 2
            default: count("jump")
            }
            largestJump = max(largestJump, abs(value - reference))
            if jumpLog.count < 24 { jumpLog.append(String(format: "%.3f@%@:%.1f", t, now.demo, value - reference)) }
        }
        if now.held || abs(value - reference) <= 1 { jumpRun = 0 }
        defer { previousValue = value }
        guard let previous, previous.isTUI == now.isTUI else { return }
        let stackMoved = now.stackTop - previous.stackTop
        let rowsMoved = now.isTUI ? now.gridTop - previous.gridTop : now.contentBottom - previous.contentBottom
        // A full-screen app's grid swaps once per toggle (its top moves with
        // the new rows, its bottom stays on the composer): only a move off
        // the composer is a snap. The swap after a one-frame `jump1` reading
        // is not one either.
        let moved = now.isTUI ? abs(value - previousValue) > 1 && abs(value - reference) > 1 : abs(rowsMoved) > 1
        if abs(stackMoved) < 0.1, moved, !now.held, !previous.held { count("snap") }
        if !now.isTUI, abs(rowsMoved) > 0.5, abs(stackMoved) > 0.1, (rowsMoved > 0) != (stackMoved > 0) { count("rev") }
    }

    private func summary(demo: String) -> String {
        let keys = ["frames", "jump", "jump1", "late", "drift", "blank", "note", "band", "snap", "rev", "sized", "hitch1", "hitch2"]
        var parts = keys.map { "\($0)=\(counts[$0] ?? 0)" }
        parts.append(String(format: "jmax=%.1f", largestJump))
        parts.append("demo=\(demo)")
        parts.append("rz=" + (stepResizes.isEmpty ? "-" : stepResizes.joined(separator: ",")))
        parts.append("jlog=" + (jumpLog.isEmpty ? "-" : jumpLog.joined(separator: ",")))
        parts.append("file=" + Self.traceURL.path.replacingOccurrences(of: " ", with: "%20"))
        return parts.joined(separator: " ")
    }
}
/// The display link's target: the link retains it, not the trace, so the
/// trace goes with its page.
@MainActor
private final class WeakTick: NSObject {
    weak var trace: TerminalFlickerTrace?
    init(_ trace: TerminalFlickerTrace) { self.trace = trace }
    @objc func step(_ link: CADisplayLink) {
        guard let trace else { return link.invalidate() }
        trace.tick(link)
    }
}
#endif
