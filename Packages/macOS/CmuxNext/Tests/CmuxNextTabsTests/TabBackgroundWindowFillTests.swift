import AppKit
import Testing
@testable import CmuxNextTabs

/// Dogfood 2026-10-08 (08): the selected tab kept its fill in a window that was
/// not in front. Only the main window's strip fills its selected tab; in a
/// background window the selected tab keeps its primary title and no fill.
@MainActor @Suite struct TabBackgroundWindowFillTests {
    @Test func aBackgroundWindowsSelectedTabHasNoFill() {
        let h = TabHoverChromeTests.Harness(titles: ["One", "Two"])
        let selected = h.strip.cells[TabID("t0")]!
        h.strip.windowMainChanged(isMain: true)
        #expect(selected.fillsSelection)
        h.strip.windowMainChanged(isMain: false)
        #expect(!selected.fillsSelection)
        h.strip.windowMainChanged(isMain: true)
        #expect(selected.fillsSelection)
    }

    @Test func theStripFollowsItsWindowBecomingAndLeavingMain() {
        let h = TabHoverChromeTests.Harness(titles: ["One", "Two"])
        let selected = h.strip.cells[TabID("t0")]!
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: h.window)
        #expect(selected.fillsSelection)
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: h.window)
        #expect(!selected.fillsSelection)
    }

    @Test func aLiftedTabKeepsItsFillInABackgroundWindow() {
        let h = TabHoverChromeTests.Harness(titles: ["One", "Two"])
        let selected = h.strip.cells[TabID("t0")]!
        h.strip.windowMainChanged(isMain: false)
        selected.isLifted = true
        #expect(selected.fillsSelection)
    }
}
