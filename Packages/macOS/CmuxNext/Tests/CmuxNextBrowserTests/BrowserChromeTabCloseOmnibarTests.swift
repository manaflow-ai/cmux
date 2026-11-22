import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-20, "cmd l not working on my computer": Shift-Cmd-L opened a New Browser Tab (its omnibar
/// edited), Cmd-W closed it, and Cmd-L never focused the address bar of the tab that showed again. A pane's tabs share
/// one omnibar (`BrowserChromeTabState`); a tab that closes while its omnibar edits must end that edit, as a tab that
/// only leaves does (`BrowserChromeTabSwitch.save`). Otherwise the field editor stays the window's first responder
/// while the next tab's omnibar state says it is not editing, and the focus model's address-bar target, which focuses
/// the bar only when the keyboard is not already inside it, never focuses it again.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeTabCloseOmnibarTests {
    @Test func aTabClosedWhileItsOmnibarEditsLeavesNoEditBehindAndCmdLFocusesTheNextTabsAddress() async throws {
        let pane = BrowserChromeTabSwitchTests.Pane()
        defer { pane.tearDown() }
        let bar = pane.chrome.addressBar
        // The new tab (B) shows, its omnibar editing as the window's first responder (Shift-Cmd-L).
        await pane.show(pane.b)
        bar.focus()
        try #require(bar.editsAsFirstResponder, "tab B's omnibar edits")

        // Cmd-W: tab B closes (its page retires from the shared chrome), then the pane shows tab A again.
        BrowserTabRetirement(tab: pane.b, state: pane.stateB).retire()
        await pane.show(pane.a)
        let responderInBar = (pane.window.firstResponder as? NSView)?.isDescendant(of: bar) == true
        #expect(!bar.isEditing, "tab A's omnibar is not editing")
        #expect(!responderInBar, "the closed tab's omnibar edit is left behind: the window's first responder \(String(describing: pane.window.firstResponder)) is in the omnibar, which says it is not editing")

        // Cmd-L: the focus model's address-bar target focuses the bar only when the keyboard is not in it already
        // (`FocusEffectApplier`), then the bar edits with tab A's address all selected.
        if !responderInBar { bar.focus() }
        #expect(bar.editsAsFirstResponder, "Cmd-L did not put the keyboard in tab A's omnibar")
        #expect(bar.debugAllSelected, "Cmd-L did not select tab A's address: \(bar.displayedText)")
        #expect(bar.displayedText.contains("a.example"), "the omnibar shows tab A's address: \(bar.displayedText)")
    }
}
