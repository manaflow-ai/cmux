import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `layout.fadeInactivePanes` (Leo, 2026-11-12: "focus anything the composer just the window the pane it
/// should fade away"): with the setting on, a pane without the focus fades under the dim, and a pane that
/// takes the focus fades back to full strength. With it off, no pane dims.
@MainActor
@Suite(.closesItsWindows) struct FadeInactivePanesTests {
    typealias Commit = PaneLayoutCommitTests

    /// Two columns that fit the screen side by side: focus moves with no camera move.
    static func twoPanes() -> [LayoutScreen] { Commit.strip([1, 2]) }

    /// A harness whose model follows the live setting (no override), with the setting at `on`. The setting is
    /// put back before the test returns: the test is synchronous on the main actor, so no other test sees it.
    static func withSetting<T>(_ on: Bool, _ body: () throws -> T) rethrows -> T {
        let before = DesignSettings.shared.fadeInactivePanes
        DesignSettings.shared.fadeInactivePanes = on
        defer { DesignSettings.shared.fadeInactivePanes = before }
        return try body()
    }

    static func overlay(_ harness: Commit.Harness, _ pane: PaneID) throws -> PaneOverlayView {
        try #require(harness.root.context.hosts[pane], "set-up: \(pane) has no host").chrome
    }

    @Test func anUnfocusedPaneFadesAndFadesBackWhenItTakesTheFocus() throws {
        try Self.withSetting(true) {
            let harness = Commit.Harness(Self.twoPanes(), focused: "p1", holds: false)
            defer { harness.window.closeAfterTest() }
            #expect(harness.model.dimsInactivePanesOverride == nil)
            try #require(harness.model.dimsInactivePanes, "layout.fadeInactivePanes on does not turn the model's dim on")
            harness.root.syncWithModel()
            Commit.rest(harness)
            let p1 = try Self.overlay(harness, "p1"), p2 = try Self.overlay(harness, "p2")
            #expect(p1.dimOpacity == 0, "the focused pane is dimmed: \(p1.dimOpacity)")
            #expect(p2.dimOpacity > 0, "the pane without the focus does not fade")
            let faded = p2.dimOpacity

            harness.model.focus("p2", notify: false)
            harness.root.syncWithModel()
            var fadedBack = p2.dimFades
            Commit.rest(harness)
            fadedBack = fadedBack || p2.dimFades
            #expect(p2.dimOpacity == 0, "the pane that took the focus stays dimmed: \(p2.dimOpacity)")
            #expect(abs(p1.dimOpacity - faded) < 0.0001, "the pane that lost the focus does not fade: \(p1.dimOpacity)")
            // The dim eases both ways over its own fade (`MotionFade.paneDim`), unless this Mac's motion is off.
            if Motion.feedback.duration(.paneDim) > 0 {
                #expect(fadedBack, "the pane that took the focus jumped back to full strength instead of fading back")
                #expect(p1.dimFades, "the pane that lost the focus jumped to its dim instead of fading")
            }
        }
    }

    @Test func withTheSettingOffNoPaneDims() throws {
        try Self.withSetting(false) {
            let harness = Commit.Harness(Self.twoPanes(), focused: "p1", holds: false)
            defer { harness.window.closeAfterTest() }
            #expect(!harness.model.dimsInactivePanes, "layout.fadeInactivePanes off still dims")
            // A Ghostty unfocused-split dim or a ringless indicator on the Mac that runs the test dims on its own.
            let style = harness.root.context.style
            guard style.inactiveDim(dimsInactive: false).amount == 0 else { return }
            harness.root.syncWithModel()
            Commit.rest(harness)
            #expect(try Self.overlay(harness, "p2").dimOpacity == 0, "a pane dims with the setting off")
        }
    }
}
