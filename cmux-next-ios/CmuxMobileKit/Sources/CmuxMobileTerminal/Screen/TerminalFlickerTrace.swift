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
/// Counted from the demo's first toggle (`show0`) to its end (`done.`).
/// A full-screen app (design/terminal R1-1, 2026-11-16): through a toggle
/// its grid stays pinned to the top (row 1 at the toolbar's edge), the
/// composer moves over its bottom rows or away from them, and the Mac's
/// grid of the new rows swaps in once:
/// - `topoff`: the grid's top (the held still's while it is up) above the
///   toolbar's edge, or more than a row below it (`topmax`).
/// - `topmove`: the same grid's top moving (riding the composer).
/// - `gapf`/`gappx`: frames with a gap between the grid's last row and the
///   composer (measured), `gaplive`: such a gap not covered by background.
/// - `off2`: a grid of the page's rows with a gap above the composer, or off
///   it by more than 2 pt once the composer stopped.
/// - `late`: the old grid still up two frames after the composer stopped.
/// - `torn`: Ghostty presented a grid of other rows than the area's with no
///   committed still over it.
/// - `swapms`: per step, toggle start to the Mac's grid on screen.
/// A shell (primary screen):
/// - `jump`/`jump1`: the last row off its gap to the composer, two or more
///   frames in a row / single frames; `drift`: more than two rows off;
///   `gapoff`/`gapmax`: a following page's last row as drawn off the
///   composer by more than the row a stream writes ahead.
/// - `rev`: frames where the rows moved against the keyboard.
/// Both:
/// - `blank`: frames with nothing legible.
/// - `note`: frames that show the letterbox note ("53×25 · set by …").
/// - `snap`: frames where the rows moved while the composer stood still.
/// - `sized`: frames where the surface changed size.
/// - `hitch1`/`hitch2`: frame intervals of two, and of three or more, frames.
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
        /// The held frame (a still over a mirror reset) as drawn: its top and
        /// bottom, and whether it is a still of the app's area (its bottom is
        /// the grid's) rather than of the whole page.
        var heldTop: CGFloat = 0
        var heldBottom: CGFloat = 0
        var heldIsArea = false
        /// The top of the background below the area (`tuiBelowCover`).
        var coverTop: CGFloat = 0
        /// The rows the page asks for now (the grid the Mac redraws to).
        var pageRows = 0
        /// The rows the area keeps for a grid on its way (0: none), the area's
        /// top inset, and the rows last sent to the Mac.
        var heldAreaRows = 0
        var areaInset: CGFloat = 0
        var sentRows = 0
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
        /// The legible band's top (under the toolbar) and the document's
        /// height, for the drawn blank test.
        var legibleTop: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    private let sample: () -> Sample?
    private var link: CADisplayLink?
    /// The page as Core Animation committed it for the last frame: read in
    /// UIKit's update right after the transaction commit
    /// (`UIUpdateActionPhase.afterCATransactionCommit`), so every change made
    /// for that frame is in the render tree, new layers included. Read on
    /// the display link or at a run loop observer, it caught changes not yet
    /// committed (iOS 26 commits inside UIKit's update, not at a run loop
    /// observer): a held still added that frame read at its model place, the
    /// area relaid under it read as moved, frames the 60 fps video of the
    /// same run never shows.
    private var committed: Sample?
    private var updateLink: UIUpdateLink?
    private let handle: FileHandle?
    private let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let start = CACurrentMediaTime()
    private var ours: [String: Double] = [:]
    private var oursTotal = 0.0

    /// The page's measured work (`TerminalViewController.measured`), by name;
    /// `outermost` work counts toward the frame's total (nested work is
    /// inside its caller's time).
    func work(_ name: String, _ seconds: CFTimeInterval, outermost: Bool) {
        ours[name, default: 0] += seconds * 1000
        if outermost { oursTotal += seconds * 1000 }
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
        let updateLink = UIUpdateLink(view: host)
        updateLink.addAction(to: .afterCATransactionCommit) { [weak self] _, _ in
            // main-proof: UIKit runs update link actions on the main thread.
            MainActor.assumeIsolated { self?.committed = self?.sample() }
        }
        // No forced updates: a frame UIKit does not update keeps the last
        // sample (the trace's display link reads it once, then samples itself).
        updateLink.isEnabled = true
        self.updateLink = updateLink
    }

    isolated deinit {
        stop()
    }

    func stop() {
        link?.invalidate()
        link = nil
        updateLink?.isEnabled = false
        updateLink = nil
    }

    private func count(_ key: String) { counts[key, default: 0] += 1 }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let host else { return stop() }
        guard let window = host.window else { return }
        if probe.window !== window { window.addSubview(probe) }
        guard let now = committed ?? sample() else { return }
        committed = nil
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
            line += String(format: " grid=%.2f rows=%d clip=%.2f pin=%.2f note=%d nb=%d page=%d hr=%d ins=%.2f sent=%d", now.gridTop, now.gridRows,
                           now.clipTop, pin, now.noteShown ? 1 : 0, now.nonBlankRows, now.pageRows, now.heldAreaRows, now.areaInset, now.sentRows)
            if now.held { line += String(format: " htop=%.2f hbot=%.2f harea=%d", now.heldTop, now.heldBottom, now.heldIsArea ? 1 : 0) }
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
        line += String(format: " ours=%.1f", oursTotal)
        if !ours.isEmpty {
            line += " parts=" + ours.sorted { $0.value > $1.value }.prefix(6).map { String(format: "%@:%.1f", $0.key, $0.value) }.joined(separator: ",")
        }
        ours.removeAll(keepingCapacity: true)
        oursTotal = 0
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
        if let previous { stackStill = abs(now.stackTop - previous.stackTop) < 0.1 ? stackStill + 1 : 0 }
        if now.isTUI {
            value = now.gridTop + CGFloat(now.gridRows) * now.cellHeight - now.stackTop
            measureShown(now, t: t)
            if !now.held, now.noteShown { count("note") }
            if !now.held, now.nonBlankRows == 0 { count("blank") }
        } else {
            value = now.stackTop - now.contentBottom
            if drawnBlank(now) { count("blank") }
        }
        let reference = reference ?? value
        self.reference = reference
        if !now.isTUI, now.cellHeight > 0, now.following {
            // Following, the last row stays on the composer every frame: at
            // most the one row a stream writes ahead of the follow scroll
            // (`gapoff`: frames past that; `gapmax`: the largest distance).
            // The last row as drawn: the document's end, or the surface's
            // bottom when the newest rows are not presented yet.
            let drawnGap = now.stackTop - min(now.contentBottom, now.surfaceBottom)
            let drawnRest = drawnGapRest ?? drawnGap
            drawnGapRest = drawnRest
            let gap = abs(drawnGap - drawnRest)
            largestGap = max(largestGap, gap)
            if gap > now.cellHeight + 1 {
                count("gapoff")
                if offLog.count < 24 { offLog.append(String(format: "%.3f@%@:gap%.1f", t, now.demo, drawnGap - drawnRest)) }
            }
        }
        if !now.isTUI, now.cellHeight > 0 {
            // Streaming adds up to a row a frame ahead of the follow scroll,
            // and the keyboard moves the composer meanwhile: two rows off.
            if abs(value - reference) > 2 * now.cellHeight {
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
        // A full-screen app's grid is checked by `topmove` (its top stands
        // still between swaps; a swap changes its rows and its bottom).
        let moved = now.isTUI ? false : abs(rowsMoved) > 1
        if abs(stackMoved) < 0.1, moved, !now.held, !previous.held { count("snap") }
        if !now.isTUI, abs(rowsMoved) > 0.5, abs(stackMoved) > 0.1, (rowsMoved > 0) != (stackMoved > 0) { count("rev") }
    }

    /// What the person sees of a full-screen app, every frame, held frames
    /// included: the grid's bottom row against the composer (`off2`: more
    /// than 2 pt from where it rests, single frames too) and the band of
    /// background between the toolbar and the grid's top (`bandf` frames,
    /// `bandpx` the largest, in points beyond the resting gap).
    private func measureShown(_ now: Sample, t: CFTimeInterval) {
        // What shows of the grid: the held still while it is up (its top and
        // bottom), else the live grid.
        let top: CGFloat, bottom: CGFloat
        if now.held {
            // A still of the whole page: where its grid is drawn is not known.
            guard now.heldIsArea else { return }
            top = now.heldTop
            bottom = now.heldBottom
        } else {
            top = now.gridTop
            bottom = now.gridTop + CGFloat(now.gridRows) * now.cellHeight
        }
        let pin = bottom - now.stackTop
        let swapped = !now.held && now.gridRows == now.pageRows
        // Row 1 at the toolbar's edge, every frame (the area's sub-row rest is
        // below it): never under the toolbar, never a band above the grid.
        if top < now.clipTop - 1 || top > now.clipTop + now.cellHeight + 1 {
            count("topoff")
            largestTopOff = max(largestTopOff, abs(top - now.clipTop))
            if offLog.count < 24 { offLog.append(String(format: "%.3f@%@:top%.1f%@", t, now.demo, top - now.clipTop, now.held ? "h" : "")) }
        }
        // While the same grid shows (no swap), its top stands still: it does
        // not ride the composer.
        if let last = lastShown, last.rows == now.gridRows, last.held == now.held, abs(top - last.top) > 1 {
            count("topmove")
            if offLog.count < 24 { offLog.append(String(format: "%.3f@%@:move%.1f", t, now.demo, top - last.top)) }
        }
        lastShown = (now.gridRows, now.held, top)
        // Below the grid's last row, down to the composer: background only
        // (the area's cover starts at the grid's bottom).
        if bottom < now.stackTop - 1 {
            count("gapf")
            largestGapBelow = max(largestGapBelow, now.stackTop - bottom)
            if now.coverTop > bottom + 1 {
                count("gaplive")
                if offLog.count < 24 { offLog.append(String(format: "%.3f@%@:live%.1f", t, now.demo, now.coverTop - bottom)) }
            }
        }
        // The grid of the page's rows rests on the composer: never a gap above
        // the composer after the swap, and on it once the composer stopped.
        if swapped, pin < -2 || (stackStill >= 2 && abs(pin) > 2) {
            count("off2")
            largestOff = max(largestOff, abs(pin))
            if offLog.count < 24 { offLog.append(String(format: "%.3f@%@:pin%.1f", t, now.demo, pin)) }
        }
        // The old grid still up once the composer stopped.
        if stackStill >= 2, !now.held, now.gridRows != now.pageRows { count("late") }
        // Toggle start to the swap (the Mac's grid of the page's rows on screen).
        if now.demo != swapStep {
            swapStep = now.demo
            swapStart = t
            swapAwaited = now.gridRows != now.pageRows || now.held
            swapRowsAtStart = now.gridRows
        }
        // A swap is awaited from the step's start while the page asks for
        // other rows than the grid on screen has (or a still is up).
        if !swapAwaited, swapRowsAtStart >= 0, now.gridRows != now.pageRows || now.held { swapAwaited = true }
        if swapAwaited, swapped, swapLog.count < 24 {
            swapLog.append(String(format: "%@:%.0f", now.demo, (t - swapStart) * 1000))
            swapAwaited = false
            swapRowsAtStart = -1
        }
    }

    private var lastShown: (rows: Int, held: Bool, top: CGFloat)?
    private var largestTopOff: CGFloat = 0
    private var largestGapBelow: CGFloat = 0
    private var swapStep = ""
    private var swapStart: CFTimeInterval = 0
    private var swapAwaited = false
    private var swapRowsAtStart = -1
    private var swapLog: [String] = []

    /// Background where the document has rows in the legible band (toolbar
    /// to composer), from the drawn geometry: the page's own check
    /// (`legibleRowsBlank`) reads model frames, which run ahead of what is
    /// drawn while the keyboard moves the offset in its animation.
    private func drawnBlank(_ now: Sample) -> Bool {
        guard now.cellHeight > 0 else { return false }
        let documentTop = now.contentBottom - now.contentHeight
        let top = max(now.legibleTop, documentTop)
        let bottom = min(now.stackTop, now.contentBottom)
        guard bottom - top >= now.cellHeight else { return false }
        let uncovered = max(0, now.surfaceTop - top) + max(0, bottom - now.surfaceBottom)
        return uncovered >= now.cellHeight
    }

    /// Ghostty presented a grid of `fed` rows in an area of `area` rows with no
    /// committed still over it (TerminalViewController.surfacePresented).
    func countTorn(fed: Int, area: Int) {
        guard measuring else { return }
        count("torn")
        if offLog.count < 24 { offLog.append("torn:\(fed)in\(area)") }
    }

    private var largestOff: CGFloat = 0
    private var largestGap: CGFloat = 0
    private var drawnGapRest: CGFloat?
    private var offLog: [String] = []

    private func summary(demo: String) -> String {
        let keys = ["frames", "topoff", "topmove", "off2", "gaplive", "gapf", "torn", "gapoff", "jump", "jump1", "late", "drift", "blank", "note", "snap", "rev", "sized", "hitch1", "hitch2"]
        var parts = keys.map { "\($0)=\(counts[$0] ?? 0)" }
        parts.append(String(format: "jmax=%.1f", largestJump))
        parts.append(String(format: "off2max=%.1f", largestOff))
        parts.append(String(format: "topmax=%.1f", largestTopOff))
        parts.append(String(format: "gappx=%.1f", largestGapBelow))
        parts.append("swapms=" + (swapLog.isEmpty ? "-" : swapLog.joined(separator: ",")))
        parts.append(String(format: "gapmax=%.1f", largestGap))
        parts.append("offlog=" + (offLog.isEmpty ? "-" : offLog.joined(separator: ",")))
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
