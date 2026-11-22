import AppKit
import CmuxNextBrowser
@testable import CmuxNextPopups
import CmuxNextTestSupport
import Foundation
import Testing

/// A password manager's popout (`chrome.windows.create`) is the person's own UI. cmux shows it over a pane
/// and names that pane's page its opener, but the page did not make it and no page script reaches it. When
/// it took the opener's agent mark, the agent URL guard replaced its `chrome-extension://` page with
/// `about:blank`: an empty window with its own location bar, and the sign-in failed (user report, GitHub
/// sudo with Bitwarden, 2026-11-18). A page's own popup still takes the mark (`window.opener` reaches it).
@MainActor @Suite(.serialized, .closesItsWindows) struct ExtensionWindowAgentMarkTests {
    private func popupOf(agentDriven: Bool) -> (BrowserPopupWindows, MockBrowserTab, NSWindow) {
        let popups = BrowserPopupWindows(activeLook: nil)
        popups.ordersWindowsIn = false
        let opener = NSWindow(contentRect: CGRect(x: 200, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        opener.isReleasedWhenClosed = false
        let popup = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/")))
        if agentDriven { popup.markAgentDriven() }
        popups.open(popup, request: BrowserPopupRequest(size: CGSize(width: 480, height: 360)), from: opener, openerKey: "tab_opener")
        return (popups, popup, opener)
    }

    private func child(extensionWindow: Bool) -> MockBrowserTab {
        let child = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: nil))
        child.isExtensionWindow = extensionWindow
        return child
    }

    @Test func anExtensionsWindowOverAnAgentsPopupStaysThePersons() {
        let (popups, popup, opener) = popupOf(agentDriven: true)
        defer { popups.closeAll(); opener.close() }
        let popout = child(extensionWindow: true)

        #expect(popups.handle(popup, .openPopup(popout, BrowserPopupRequest(size: CGSize(width: 380, height: 420)))))
        #expect(!popout.isAgentDriven, "its chrome-extension:// page must load, not about:blank")
    }

    @Test func aPagesOwnPopupOfAnAgentsPopupIsTheAgents() {
        let (popups, popup, opener) = popupOf(agentDriven: true)
        defer { popups.closeAll(); opener.close() }
        let nested = child(extensionWindow: false)

        #expect(popups.handle(popup, .openPopup(nested, BrowserPopupRequest(size: CGSize(width: 380, height: 420)))))
        #expect(nested.isAgentDriven, "window.opener reaches it: no saved password, no passkey")
    }
}
