import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The tab bar's + and a toast's buttons say what they do (affordance audit 2026-10-21): the +
/// names New Tab, its shortcut and that holding it opens more; an Undo toast's button shows the
/// Cmd-Z that also runs it (the web toast stack draws the buttons and their identifiers).
@MainActor @Suite(.serialized, .closesItsWindows) struct TabBarToastIconMeaningTests {
    @Test func theNewTabPlusSaysHoldForMoreAndShowsItsShortcut() {
        let strip = TabStripView(model: TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "zsh")], selectedID: TabID("t0")))
        #expect(strip.newTabButton.themedToolTip == Strings.newTabHoldHint)
        #expect(strip.newTabButton.accessibilityLabel() == Strings.axNewTab)

        // The shortcut is read when the pointer comes onto the +, so a rebinding shows at once.
        var shortcut = "⌘T"
        strip.newTabShortcut = { shortcut }
        strip.newTabButton.isHovered = true
        #expect(strip.newTabButton.themedToolTipShortcut == "⌘T")
        strip.newTabButton.isHovered = false
        shortcut = "⌃⌘T"
        strip.newTabButton.isHovered = true
        #expect(strip.newTabButton.themedToolTipShortcut == "⌃⌘T")
        #expect(strip.newTabButton.themedToolTip == Strings.newTabHoldHint)
    }

    /// The screen bar's + makes a screen: it keeps no New Tab tooltip.
    @Test func aStripCanDropThePlusTooltip() {
        let strip = TabStripView(model: TabStripModel())
        strip.newTabToolTip = nil
        strip.newTabShortcut = { "⌘T" }
        strip.newTabButton.isHovered = true
        #expect(strip.newTabButton.themedToolTip == nil)
        #expect(strip.newTabButton.themedToolTipShortcut == nil)
    }

    /// An Undo toast is shown with its key (the host draws ⌘Z on its button); a Reopen (not an
    /// Undo) has no key.
    @Test func anUndoToastShowsCmdZAndAReopenNone() throws {
        let host = ShownToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let undo = center.show(CmuxToast(id: "tab-closed", message: "Closed “zsh”", action: .undo()), in: window)
        let shownUndo = try #require(host.shown.last)
        #expect(shownUndo.toast.action?.title == CmuxToastStrings.undo)
        #expect(shownUndo.showsUndoKey)
        undo.dismiss()

        let reopen = center.show(CmuxToast(id: "window-closed", message: "Closed a window", action: .reopen()), in: window)
        let shownReopen = try #require(host.shown.last)
        #expect(shownReopen.toast.action?.title == CmuxToastStrings.reopen)
        #expect(!shownReopen.showsUndoKey)
        reopen.dismiss()
    }
}

/// Keeps the window's toasts as the center last showed them.
@MainActor
private final class ShownToastHost: CmuxToastHosting {
    private(set) var shown: [CmuxToastShown] = []
    func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) { shown = toasts }
}
