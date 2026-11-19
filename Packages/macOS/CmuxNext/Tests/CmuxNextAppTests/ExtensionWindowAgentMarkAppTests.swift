import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// A password manager's popout (`chrome.windows.create`, Bitwarden's fido2 window) is the person's own UI.
/// cmux shows it over a web pane and names that pane's tab its opener; when that tab was agent-driven, or
/// an agent touched it later, the popout took the agent mark and the agent URL guard replaced its
/// `chrome-extension://` page with `about:blank`. The person saw an empty window with its own location
/// bar and GitHub's sudo page said "Authentication failed" (user report, 2026-11-18). Chrome has no such
/// mark: an extension's window always shows its page. A page's own popup still takes the mark
/// (`window.opener` reaches it: no saved password, no passkey).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ExtensionWindowAgentMarkAppTests {
    private func child(extensionWindow: Bool) -> MockBrowserTab {
        let child = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: nil))
        child.isExtensionWindow = extensionWindow
        return child
    }

    @Test func anExtensionsPopoutNeverTakesItsOpenersAgentMark() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            let created = try await connection.newFrontendBrowserTab(url: "https://github.com/sessions/sudo", engine: .webkit,
                                                                      in: pane.pane.handle, activate: true)
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil }, report: {
                WindowStateReport.describe(services, surface: created.surface)
            })
            let model = try #require(services.daemon.store.tab(surface: created.surface))
            let controller = try #require(services.paneController(for: pane.pane))
            try await PinnedPageTests.until({ pane.pane.tabs.contains { $0.id == model.id } })
            controller.select(TabID(model.id), source: .intent)
            try await PinnedPageTests.until({ services.cache.existingBrowser(model.id) != nil }, report: {
                WindowStateReport.describe(services, surface: created.surface)
            })
            let opener = try #require(services.cache.existingBrowser(model.id)?.tab)
            let request = BrowserPopupRequest(size: CGSize(width: 380, height: 420))
            defer { services.popups.closeAll() }

            // Shown while the person's tab is theirs, then an agent touches that tab.
            let popout = child(extensionWindow: true), pagePopup = child(extensionWindow: false)
            services.cache.pageRequests.browserTab(opener, didRequest: .openPopup(popout, request))
            services.cache.pageRequests.browserTab(opener, didRequest: .openPopup(pagePopup, request))
            #expect(services.popups.openerKey(of: popout) == model.id)
            _ = AppBrowserPage.markAgentDriven(model.id, services: services)
            #expect(pagePopup.isAgentDriven, "a page's popup: window.opener reaches it")
            #expect(!popout.isAgentDriven, "the agent's touch on the pane's tab blanked the password manager's window")

            // Shown over a tab that is already agent-driven.
            let laterPopout = child(extensionWindow: true), laterPagePopup = child(extensionWindow: false)
            services.cache.pageRequests.browserTab(opener, didRequest: .openPopup(laterPopout, request))
            services.cache.pageRequests.browserTab(opener, didRequest: .openPopup(laterPagePopup, request))
            #expect(laterPagePopup.isAgentDriven)
            #expect(!laterPopout.isAgentDriven, "its chrome-extension:// page must load, not about:blank")
        }
    }
}
