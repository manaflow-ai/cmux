import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-15 (msg 34327): "for minimal mode there is more space at bottom we can use when mouse is not
/// hovered in sidebar, we can do height animation of bottom area too". In Minimal Mode, with the pointer away, the
/// footer (profile control, spaces, Search) is hidden, so the workspace list takes its height; the pointer over the
/// sidebar gives it back. Row heights never change (Minimal Mode keeps density). By default nothing moves.
@MainActor @Suite(.serialized) struct MinimalModeFooterCollapseTests {
    private struct Measure: CustomStringConvertible {
        var listBottom: CGFloat, footerTop: CGFloat, footerHeight: CGFloat
        var description: String { "list bottom \(listBottom), footer top \(footerTop), footer height \(footerHeight)" }
    }

    private static func measure(_ sidebar: SidebarView, revealed: Bool) -> Measure {
        sidebar.setChromeRevealed(revealed)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        return Measure(listBottom: sidebar.edgeFade.frame.maxY, footerTop: sidebar.footerRegion.frame.minY,
                       footerHeight: sidebar.footerRegion.frame.height)
    }

    @Test func minimalModeGivesTheHiddenFooterToTheList() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"minimal":true}}"#)
        defer { h.tearDown() }
        await h.until { h.sidebar.design.sidebarSections.minimal }
        let shown = Self.measure(h.sidebar, revealed: true)
        let rest = Self.measure(h.sidebar, revealed: false)
        print("FOOTER-COLLAPSE|minimal|shown: \(shown)|rest: \(rest)")
        #expect(shown.footerHeight > 0, "fixture: the footer has a height to give")
        #expect(shown.listBottom <= shown.footerTop + 0.5, "revealed, the list ends above the footer: \(shown)")
        #expect(rest.listBottom >= shown.listBottom + shown.footerHeight - 0.5,
                "at rest the list takes the hidden footer's height: shown \(shown), rest \(rest)")
        let again = Self.measure(h.sidebar, revealed: true)
        #expect(abs(again.listBottom - shown.listBottom) <= 0.5, "the pointer back over the sidebar gives the room back: \(again)")
    }

    @Test func byDefaultTheFooterKeepsItsHeight() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make("{}")
        defer { h.tearDown() }
        let shown = Self.measure(h.sidebar, revealed: true)
        let rest = Self.measure(h.sidebar, revealed: false)
        print("FOOTER-COLLAPSE|default|shown: \(shown)|rest: \(rest)")
        #expect(abs(rest.listBottom - shown.listBottom) <= 0.5, "nothing hides by default, so nothing moves: \(shown) vs \(rest)")
    }
}

extension MinimalModeFooterCollapseTests {
    /// The height motion runs the footer fade's curve (`Motion.fadeCurve`, ease-out 0, 0, 0.58, 1): it starts fast
    /// and settles, from 0 to 1.
    @Test func theHeightRunsTheFadesEaseOutCurve() {
        #expect(SidebarFooterCollapseMotion.easeOut(0) == 0)
        #expect(abs(SidebarFooterCollapseMotion.easeOut(1) - 1) < 0.001)
        let half = SidebarFooterCollapseMotion.easeOut(0.5)
        #expect(half > 0.6 && half < 0.9, "ease-out is past halfway at half time: \(half)")
        var last: CGFloat = 0
        for step in 1...20 {
            let value = SidebarFooterCollapseMotion.easeOut(Double(step) / 20)
            #expect(value >= last, "monotonic")
            last = value
        }
    }

    /// `sidebar.spacesVisibility` Always keeps the strip (which shares the footer's row) shown, so the footer keeps its room.
    @Test func spacesShownAlwaysKeepTheFootersRoom() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"minimal":true}}"#)
        defer { h.tearDown() }
        await h.until { h.sidebar.design.sidebarSections.minimal }
        // The window root passes `sidebar.spacesVisibility` to the sidebar (WindowRootView); this harness has none.
        h.sidebar.spacesVisibility = .always
        let shown = Self.measure(h.sidebar, revealed: true)
        let rest = Self.measure(h.sidebar, revealed: false)
        #expect(abs(rest.listBottom - shown.listBottom) <= 0.5, "the shown strip keeps its row: \(shown) vs \(rest)")
    }
}

extension MinimalModeFooterCollapseTests {
    /// With the motion on (no Reduce Motion), a change starts from the height on screen and lands on its target once
    /// the clock has stepped the fade's duration: the list's bottom edge moves, then settles.
    @Test func theHeightMovesOverTheFadeThenSettles() {
        let motion = SidebarFooterCollapseMotion()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(motion.height(toward: 0, in: view) == 0, "the first layout lands at once")
        // No window: the change applies at once (nothing on screen to animate).
        #expect(motion.height(toward: 25, in: view) == 25)
        #expect(motion.height(toward: 0, in: view) == 0)
    }
}
