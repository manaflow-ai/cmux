import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// The animation pixel harness on its simplest case (Lawrence 2026-11-01: "resizing columns and
/// rows needs tests to ensure pixel perfect animations"; cmux-ad's design, plan in STATUS 2691):
/// an explicit equalize of a split, which springs on `move` (plans/cmux-next/motion.md, "Pane
/// ratio, equalize, width presets"). Every frame the window server shows, at 120 Hz, 1x and 2x,
/// light and dark, is judged against the declared spring: on the pixel grid, no gap or overlap,
/// within 1 device pixel of the curve, monotonic, the exact final layout, no dropped frame. With
/// the master animation switch off the same change lands in one frame.
///
/// A display step runs these (`cmux-ci run --display`, CMUX_TEST_REQUIRE_GUI=1); without a screen
/// there they fail (the virtual display or the capture throws), never skip.
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || NSScreen.main != nil,
                "animation pixel tests draw on a display: a display step runs them and fails without a screen"))
struct AnimationPixelHarnessTests {
    static let layout = ScreenLayout.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2")))

    @Test(arguments: [1, 2], [false, true])
    func anEqualizeMovesEveryEdgeOnTheDeclaredSpringOnThePixelGrid(scale: Int, dark: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: Self.layout, focused: "p1", scale: scale, dark: dark)
        defer { fixture.close() }
        let run = AnimationPixelRun(fixture: fixture, name: "equalize-\(scale)x-\(dark ? "dark" : "light")")
        let failures = try await run.judge(.row, spring: .move, animated: true) { fixture.model.equalizeSplit("x") }
        Self.record(failures)
    }

    @Test(arguments: [1, 2])
    func withAnimationsOffAnEqualizeLandsInOneFrame(scale: Int) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: Self.layout, focused: "p1", scale: scale, dark: false, animations: false)
        defer { fixture.close() }
        let run = AnimationPixelRun(fixture: fixture, name: "equalize-off-\(scale)x")
        let failures = try await run.judge(.row, spring: .move, animated: false) { fixture.model.equalizeSplit("x") }
        Self.record(failures)
    }

    /// One issue per failure, at most 20, then the count of the rest.
    static func record(_ failures: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for failure in failures.prefix(20) { Issue.record(Comment(rawValue: failure), sourceLocation: sourceLocation) }
        if failures.count > 20 { Issue.record("and \(failures.count - 20) more failures (the log has the frame data)", sourceLocation: sourceLocation) }
    }
}
