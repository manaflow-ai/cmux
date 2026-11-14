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
/// - `jump`: frames where the rows on screen are not where they belong. A
///   full-screen app's grid ends on the composer stack's top (`pin`, its
///   bottom edge minus the stack's top, against the value at rest); a
///   shell's last row keeps its gap above the stack (`gap`). A held frame
///   (the still over a mirror reset) is what was on screen and counts as
///   placed.
/// - `blank`: frames with nothing legible: a full-screen app's grid with no
///   text, or a shell page showing background where it has rows.
/// - `note`: frames that show the letterbox note ("53×25 · set by …").
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
    }

    private let sample: () -> Sample?
    private var link: CADisplayLink?
    private let handle: FileHandle?
    private let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let start = CACurrentMediaTime()
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
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private func count(_ key: String) { counts[key, default: 0] += 1 }

    @objc private func tick(_ link: CADisplayLink) {
        guard let host, let window = host.window else { return }
        if probe.window !== window { window.addSubview(probe) }
        guard let now = sample() else { return }
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
            line += String(format: " cb=%.2f gap=%.2f blank=%d", now.contentBottom, now.stackTop - now.contentBottom, now.legibleBlank ? 1 : 0)
        }
        if measuring { measure(now, t: t, interval: interval, duration: duration) }
        if measuring, now.demo.hasPrefix("done.") {
            measuring = false
            finished = true
            stepResizes.append("\(step):\(now.resizes - stepStartResizes)")
        }
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
            if now.noteShown { count("note") }
            if !now.held, now.nonBlankRows == 0 { count("blank") }
            if !now.held, now.gridTop - now.clipTop > now.cellHeight { count("band") }
        } else {
            value = now.stackTop - now.contentBottom
            if now.legibleBlank { count("blank") }
        }
        let reference = reference ?? value
        self.reference = reference
        if !now.held, abs(value - reference) > 1 {
            count("jump")
            largestJump = max(largestJump, abs(value - reference))
            if jumpLog.count < 24 { jumpLog.append(String(format: "%.3f@%@:%.1f", t, now.demo, value - reference)) }
        }
        guard let previous, previous.isTUI == now.isTUI else { return }
        let stackMoved = now.stackTop - previous.stackTop
        let rowsMoved = now.isTUI ? now.gridTop - previous.gridTop : now.contentBottom - previous.contentBottom
        if abs(stackMoved) < 0.1, abs(rowsMoved) > 1, !now.held, !previous.held { count("snap") }
        if !now.isTUI, abs(rowsMoved) > 0.5, abs(stackMoved) > 0.1, (rowsMoved > 0) != (stackMoved > 0) { count("rev") }
    }

    private func summary(demo: String) -> String {
        let keys = ["frames", "jump", "blank", "note", "band", "snap", "rev", "sized", "hitch1", "hitch2"]
        var parts = keys.map { "\($0)=\(counts[$0] ?? 0)" }
        parts.append(String(format: "jmax=%.1f", largestJump))
        parts.append("demo=\(demo)")
        parts.append("rz=" + (stepResizes.isEmpty ? "-" : stepResizes.joined(separator: ",")))
        parts.append("jlog=" + (jumpLog.isEmpty ? "-" : jumpLog.joined(separator: ",")))
        parts.append("file=" + Self.traceURL.path.replacingOccurrences(of: " ", with: "%20"))
        return parts.joined(separator: " ")
    }
}
#endif
