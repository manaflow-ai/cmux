import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The tab bar's + and a toast's buttons say what they do (affordance audit 2026-10-21): the +
/// names New Tab, its shortcut and that holding it opens more; an Undo toast's button shows the
/// Cmd-Z that also runs it; every toast button has a stable identifier for agents and UI tests.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabBarToastIconMeaningTests {
    private let audit = AccessibilityAudit()

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

    @Test func anUndoToastShowsCmdZAndEveryButtonIsIdentified() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "tab-closed", message: "Closed “zsh”", action: .undo()))
        let undo = try #require(view.actionButton)
        #expect(undo.themedToolTip == CmuxToastStrings.undo)
        #expect(undo.themedToolTipShortcut == "⌘Z")
        // VoiceOver reads the title once; the help adds only the key, not "Undo" again.
        #expect(undo.accessibilityHelp() == "⌘Z")
        #expect(undo.accessibilityIdentifier() == "cmux.toast.tab-closed.action")
        #expect(view.closeButton.accessibilityIdentifier() == "cmux.toast.tab-closed.close")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let violations = audit.violations(under: view)
        #expect(violations.isEmpty, "toast: \(violations.joined(separator: "\n"))")
    }

    /// A Reopen (not an Undo) has no key: no shortcut, and no tooltip repeating its title.
    @Test func aReopenToastShowsNoShortcut() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "window-closed", message: "Closed a window", action: .reopen()))
        let reopen = try #require(view.actionButton)
        #expect(reopen.themedToolTipShortcut == nil)
        #expect(reopen.themedToolTip == nil)
        #expect(reopen.accessibilityIdentifier() == "cmux.toast.window-closed.action")
    }
}
