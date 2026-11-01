import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// A window resize, judged on every 120 Hz frame the window server shows (plan in STATUS 2691).
/// The window narrows by 4 pt a display refresh and widens back (its right edge moves, its top
/// stays). Each drawn frame shows the window at some width; at that width the layout model
/// (`ScreenGeometry.compute`) says where every pane and divider is, and the frame must show
/// exactly that: no pane laid out for an older width (content lagging its window shows as a band
/// of background or a pane cut off), no blended pixel, no gap or overlap, within 1 device pixel.
/// A width shown is one the test set; a refresh with no new frame while the width changed is a
/// dropped frame. 1x and 2x, light and dark.
///
/// Limit: the width changes by `NSWindow.setFrame` at each refresh, not by a person's drag of the
/// window edge (AppKit's live resize, `inLiveResize`).
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || NSScreen.main != nil,
                "animation pixel tests draw on a display: a display step runs them and fails without a screen"))
struct WindowResizePixelTests {
    static let layout = ScreenLayout.splits(.split("x", axis: .horizontal, ratio: 0.4, a: .leaf("p1"),
                                                   b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))

    @Test(arguments: [1, 2], [false, true])
    func everyFrameOfAWindowResizeShowsTheLayoutAtTheWidthItShows(scale: Int, dark: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: Self.layout, focused: "p1", scale: scale, dark: dark)
        defer { fixture.close() }
        let failures = try await Self.judgeResize(fixture, name: "resize-\(scale)x-\(dark ? "dark" : "light")",
                                                  widths: (0..<40).map { 1200 - 4 * Double($0 + 1) } + (0..<40).map { 1044 + 4 * Double($0) })
        AnimationPixelHarnessTests.record(failures)
    }

    @available(macOS 14.4, *)
    static func judgeResize(_ fixture: LayoutPixelFixture, name: String, widths: [Double]) async throws -> [String] {
        let window = fixture.window, scale = fixture.scale, period = fixture.display.refreshPeriod
        let height = Int((window.frame.height * scale).rounded()), fullWidth = Int((window.frame.width * scale).rounded())
        let rowY = height / 2
        try await Task.sleep(for: .milliseconds(300))
        let stream = WindowFrameStream(rowY: rowY, columnX: 0)
        try await stream.start(window: window)
        try await Task.sleep(for: .milliseconds(300))
        guard let rest = stream.lastImage else {
            await stream.stop()
            try stream.requireUninterrupted()
            throw AnimationPixelRun.Failure(description: "\(name): ScreenCaptureKit gave no frame of the window at rest")
        }
        let style = fixture.model.style
        func expected(width: Double) -> [ScanlineSpan] {
            let geometry = ScreenGeometry.compute(Self.layout, viewport: CGSize(width: width, height: window.frame.height), style: style, scale: scale)
            var found: [ScanlineSpan] = []
            for (pane, rect) in geometry.panes {
                found.append(ScanlineSpan(label: pane.rawValue, start: Double(rect.minX * scale), end: Double(rect.maxX * scale), exactLength: nil))
            }
            for divider in geometry.dividers {
                found.append(ScanlineSpan(label: "divider:\(divider.id.rawValue)", start: Double(divider.frame.minX * scale),
                                          end: Double(divider.frame.maxX * scale), exactLength: Int((style.dividerThickness * scale).rounded())))
            }
            return ScanlineSpan.tile(found, length: Int((width * scale).rounded()))
        }
        var palette = ScanlinePalette()
        for element in expected(width: window.frame.width) {
            let center = Int(((element.start + element.end) / 2).rounded(.down))
            try palette.learn(element.color, rest.pixel(x: center, y: rowY))
        }
        let sampler = PresentationSampler(window: window, views: fixture.sampledViews)
        let driver = WindowWidthDriver(window: window, widths: widths)
        let trigger = CACurrentMediaTime()
        try await driver.run()
        try await fixture.settle()
        try await Task.sleep(for: .milliseconds(300))
        sampler.stop()
        await stream.stop()
        try stream.requireUninterrupted()

        var failures: [String] = [], shownWidths: [(time: Double, width: Double)] = []
        let allowed = Set(([Double(window.frame.width)] + widths + [1200]).map { Int(($0 * Double(scale)).rounded()) })
        let captured = stream.captured
        let grid = ScanlineJudge.onVsyncGrid(captured.map(\.time), link: sampler.samples.map(\.time), period: period)
        failures += grid.invalid
        for (index, (time, frame)) in zip(grid.times, captured).enumerated() where time >= trigger - period {
            let at = "frame \(index) (t=\(AnimationPixelRun.ms(time - trigger)) ms)"
            // The window's extent on the row: its opaque pixels (the capture is transparent past a narrower window).
            guard let first = frame.row.firstIndex(where: { $0 >> 24 != 0 }), let last = frame.row.lastIndex(where: { $0 >> 24 != 0 }) else {
                failures.append("\(at): the row shows no window pixel")
                continue
            }
            let extent = last + 1 - first
            guard allowed.contains(extent) else {
                failures.append("\(at): the window shows \(extent) px wide, not a width the test set (\(fullWidth) px at rest): scaled or torn")
                continue
            }
            shownWidths.append((time: time, width: Double(extent) / Double(scale)))
            let runs = palette.runs(Array(frame.row[first...last]))
            let due = expected(width: Double(extent) / Double(scale))
            let labels = due.map(\.color), bounds = due.dropLast().map { Int($0.end.rounded()) }
            if runs.map(\.name) != labels {
                failures.append("\(at): at \(extent) px the row reads \(runs), the layout at that width is "
                    + "\(due.map { "\($0.label)[\(Int($0.start.rounded()))..<\(Int($0.end.rounded()))]" }): content laid out for another width, a blend or a gap")
                continue
            }
            for (shown, place) in zip(runs.dropLast().map(\.end), bounds) where abs(shown - place) > Int(ScanlineJudge.curveTolerance) {
                failures.append("\(at): at \(extent) px a boundary shows at \(shown) px, the layout puts it at \(place) px")
            }
            for (run, element) in zip(runs, due) where element.exactLength.map({ $0 != run.length }) == true {
                failures.append("\(at): \(element.label) is \(run.length) px, not \(element.exactLength ?? 0)")
            }
        }
        // The last frame: the window back at its starting width, the layout exactly.
        if let last = shownWidths.last, abs(last.width - (widths.last ?? 0)) > 0.01 {
            failures.append("the last frame shows the window \(last.width) pt wide, not \(widths.last ?? 0) pt")
        }
        // Dropped frames: a refresh with a new width set and no new frame.
        let moves = driver.moves
        for (a, b) in zip(shownWidths, shownWidths.dropFirst()) where b.time - a.time > 1.5 * period {
            let changed = moves.contains { $0.time > a.time - period && $0.time < b.time - period }
            if changed {
                failures.append("dropped \(Int(((b.time - a.time) / period).rounded()) - 1) frame(s) at t=\(AnimationPixelRun.ms(a.time - trigger)) ms: "
                    + "\(AnimationPixelRun.ms(b.time - a.time)) ms with no new frame while the width changed")
            }
        }
        failures += sampler.gridFailures(from: trigger - period, scale: scale)
        let intervals = zip(shownWidths.dropFirst(), shownWidths).map { $0.time - $1.time }.sorted()
        print("ANIMATION-PIXEL \(name): scale \(Int(scale))x, \(window.effectiveAppearance.name.rawValue), \(shownWidths.count) frames for "
            + "\(moves.count) widths, intervals p50 \(AnimationPixelRun.ms(intervals.isEmpty ? 0 : intervals[intervals.count / 2])) ms max "
            + "\(AnimationPixelRun.ms(intervals.last ?? 0)) ms, \(failures.count) failures")
        for failure in failures.prefix(40) { print("ANIMATION-PIXEL \(name): FAIL \(failure)") }
        return failures
    }
}

/// Sets the window's width, keeping its top-left corner, once per display refresh.
@MainActor
final class WindowWidthDriver: NSObject {
    private(set) var moves: [(time: Double, width: Double)] = []
    private let window: NSWindow
    private var widths: [Double]
    private var link: CADisplayLink?
    private var done = false

    init(window: NSWindow, widths: [Double]) {
        self.window = window
        self.widths = widths
        super.init()
    }

    func run() async throws {
        // concurrency-allow: a test's own display link, invalidated when the widths end
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        while !done { try await Task.sleep(for: .milliseconds(5)) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !widths.isEmpty else {
            done = true
            link.invalidate()
            self.link = nil
            return
        }
        let width = widths.removeFirst()
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        moves.append((link.timestamp, width))
    }
}
