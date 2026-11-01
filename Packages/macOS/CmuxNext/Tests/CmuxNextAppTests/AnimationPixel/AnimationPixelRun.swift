import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import Foundation
import QuartzCore
import Testing

/// One captured layout animation, judged on both channels: the pixels the window server
/// composited (``WindowFrameStream`` + ``ScanlineJudge``) and the views' rects at every refresh
/// (``PresentationSampler``). The expected frames come from the declared spring
/// (``DeclaredSpring``) and the layout model's start and end geometry, never from the animator.
@available(macOS 14.4, *)
@MainActor
struct AnimationPixelRun {
    let fixture: LayoutPixelFixture
    let name: String

    typealias Axis = ScanlineAxis

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    /// Applies `change` to the fixture's model (then syncs the view in the same turn), captures
    /// every frame until the layout rests, and judges them against `spring` (`animated`) or a
    /// one-frame landing (animations off). Returns the failures; prints the frame data either way.
    func judgeSpring(_ axis: Axis, spring token: MotionSpring, animated: Bool, change: () -> Void) async throws -> [String] {
        var springs = false
        let period = fixture.display.refreshPeriod
        let declared = try DeclaredSpring.declared(token)
        var failures = try await judge(axis, moves: animated, oracle: { ScanlineOracle.spring(declared, $0, period: period) }) {
            change()
            fixture.root.syncWithModel()
            springs = fixture.screen?.hasMotion ?? false
        }
        if springs != animated {
            failures.insert(animated ? "the change did not animate (no motion after it)" : "the change animated with animations off", at: 0)
        }
        return failures
    }

    /// Captures the window at rest, runs `change` (which may take many frames, a drag), waits for
    /// the layout to rest, and judges every captured frame along `axis` against the oracle
    /// `makeOracle` builds from the scanline's elements (built after `change`, so a drag's oracle
    /// can read the pointer path it posted). Returns the failures; prints the frame data either way.
    func judge(_ axis: Axis, moves: Bool, oracle makeOracle: ([ScanlineElement]) throws -> ScanlineOracle,
               change: () async throws -> Void) async throws -> [String] {
        let window = fixture.window, scale = fixture.scale
        let screen = try #require(fixture.screen)
        let width = Int((window.frame.width * scale).rounded()), height = Int((window.frame.height * scale).rounded())
        let rowY = height / 2, columnX = width / 2
        try await Task.sleep(for: .milliseconds(300))
        let stream = WindowFrameStream(rowY: rowY, columnX: columnX)
        try await stream.start(window: window)
        try await Task.sleep(for: .milliseconds(300))
        guard let rest = stream.lastImage else {
            await stream.stop()
            throw Failure(description: "\(name): ScreenCaptureKit gave no frame of the window at rest "
                + "(\(stream.idleFrames) idle frames, stop error: \(stream.stopError ?? "none"))")
        }
        let line: (WindowFrameStream.Image) -> [UInt32] = { image in
            axis == .row ? (0..<image.width).map { image.pixel(x: $0, y: rowY) } : (0..<image.height).map { image.pixel(x: columnX, y: $0) }
        }
        let before = elements(screen, axis: axis, at: CGFloat(axis == .row ? rowY : columnX) / scale, length: axis == .row ? width : height)
        var palette = ScanlinePalette()
        for element in before {
            let center = Int(((element.start + element.end) / 2).rounded(.down))
            try palette.learn(element.label, axis == .row ? rest.pixel(x: center, y: rowY) : rest.pixel(x: columnX, y: center))
        }
        let restRuns = palette.runs(line(rest))
        guard restRuns.map(\.name) == before.map(\.label), Array(restRuns.dropLast().map(\.end)) == before.dropLast().map({ Int($0.end.rounded()) }) else {
            await stream.stop()
            throw Failure(description: "\(name): the window at rest reads \(restRuns), the layout says "
                + "\(before.map { "\($0.label)[\($0.start)..<\($0.end)]" })")
        }
        let sampler = PresentationSampler(window: window, views: fixture.sampledViews)
        let trigger = CACurrentMediaTime()
        try await change()
        try await fixture.settle()
        let after = elements(screen, axis: axis, at: CGFloat(axis == .row ? rowY : columnX) / scale, length: axis == .row ? width : height)
        // The last frames reach the window server and the stream a few refreshes after the layout rests.
        try await Task.sleep(for: .milliseconds(300))
        sampler.stop()
        await stream.stop()

        var failures: [String] = []
        let shapes = stream.frameShapes
        if shapes.contains(where: { $0.width != width || $0.height != height || ($0.contentScale != 0 && $0.contentScale != 1) }) {
            failures.append("captured frames are not the window's \(width)x\(height) device pixels unscaled: \(shapes)")
        }
        let structural = before.map(\.label) != after.map(\.label)
        let tracked = Self.track(before: before, after: after)
        let oracle = try makeOracle(tracked)
        var judge = ScanlineJudge(oracle: oracle, elements: tracked, trigger: trigger, period: fixture.display.refreshPeriod)
        if structural { judge.previous = (labels: before.map(\.label), boundaries: before.dropLast().map { Int($0.end.rounded()) }) }
        let frames = stream.captured.map { (time: $0.time, line: axis == .row ? $0.row : $0.column) }
        let verdict = judge.judge(frames, palette: palette, moves: moves)
        failures += verdict.failures
        failures += sampler.gridFailures(from: trigger - fixture.display.refreshPeriod, scale: scale)
        if moves {
            let end = sampler.samples.last { $0.rects != sampler.samples.last?.rects }?.time ?? trigger
            for gap in sampler.missedRefreshes(from: trigger, to: end, period: fixture.display.refreshPeriod) {
                failures.append("the main thread missed a display refresh in the motion: \(String(format: "%.1f", gap)) ms between ticks")
            }
        }
        print("ANIMATION-PIXEL \(name): scale \(Int(scale))x, \(window.effectiveAppearance.name.rawValue), refresh "
            + "\(String(format: "%.2f", fixture.display.refreshPeriod * 1000)) ms, \(frames.count) complete and \(stream.idleFrames) idle "
            + "frames (ScreenCaptureKit own-process capture, no Screen Recording grant asked), \(failures.count) failures")
        for line in verdict.report { print("ANIMATION-PIXEL \(name): \(line)") }
        for failure in failures.prefix(40) { print("ANIMATION-PIXEL \(name): FAIL \(failure)") }
        return failures
    }

    /// The scanline's elements after a change, each with where it was before: a pane or divider
    /// at its old place, a new one at its target (it shows at once), a background run between
    /// where its neighbours were. A pane or divider that left (a close) is not in the result:
    /// the judge sees the layout before the change as the previous structure.
    static func track(before: [ScanlineSpan], after: [ScanlineSpan]) -> [ScanlineElement] {
        var old: [String: (start: Double, end: Double)] = [:]
        for span in before where span.label != "background" && old[span.label] == nil { old[span.label] = (start: span.start, end: span.end) }
        var spans: [(start: Double, end: Double)?] = []
        for span in after {
            if span.label == "background" {
                spans.append(nil)
            } else {
                spans.append(old[span.label] ?? (start: span.start, end: span.end))
            }
        }
        for index in spans.indices where spans[index] == nil {
            let start: Double = index > 0 ? (spans[index - 1]?.end ?? 0) : 0
            let end: Double = index + 1 < spans.count ? (spans[index + 1]?.start ?? after[index].end) : after[index].end
            spans[index] = (start: start, end: max(start, end))
        }
        var elements: [ScanlineElement] = []
        for (span, was) in zip(after, spans) {
            elements.append(ScanlineElement(label: span.label, before: was ?? (start: span.start, end: span.end), after: (start: span.start, end: span.end),
                                            exactLength: span.exactLength))
        }
        return elements
    }

    /// What a scanline at `position` (points, top-left origin) along `axis` crosses at the layout's
    /// targets: the panes and divider lines across it, and background between and around them, in
    /// device pixels.
    func elements(_ screen: ScreenContentView, axis: Axis, at position: CGFloat, length: Int) -> [ScanlineSpan] {
        let scale = fixture.scale, thickness = Int((fixture.model.style.dividerThickness * scale).rounded())
        let origin = screen.convert(CGPoint.zero, to: fixture.root)
        var found: [ScanlineSpan] = []
        func add(_ label: String, _ local: CGRect, exact: Int?) {
            let rect = local.offsetBy(dx: origin.x, dy: origin.y)
            let crosses = axis == .row ? rect.minY <= position && position < rect.maxY : rect.minX <= position && position < rect.maxX
            guard crosses else { return }
            let low = axis == .row ? rect.minX : rect.minY, high = axis == .row ? rect.maxX : rect.maxY
            found.append(ScanlineSpan(label: label, start: Double(low * scale), end: Double(high * scale), exactLength: exact))
        }
        // Strip frames are in strip space: on screen they move by the camera's shift at its target.
        let geometry = screen.geometry
        let shift = geometry.viewShift(offset: screen.scroll.target)
        for (pane, rect) in geometry.panes {
            add(pane.rawValue, geometry.scrolls(pane: pane) ? rect.offsetBy(dx: shift, dy: 0) : rect, exact: nil)
        }
        for divider in geometry.dividers where (axis == .row) == (divider.frame.height > divider.frame.width) {
            let rect = geometry.fixedSplits.contains(divider.id) ? divider.frame : divider.frame.offsetBy(dx: shift, dy: 0)
            add("divider:\(divider.id.rawValue)", rect, exact: thickness)
        }
        return ScanlineSpan.tile(found, length: length)
    }
}
