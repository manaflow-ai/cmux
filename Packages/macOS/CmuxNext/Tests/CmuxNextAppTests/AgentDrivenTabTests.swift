import AppKit
import CmuxNextBrowser
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// A tab an agent drove never gets saved passwords filled again, including
/// the page that replaces it after hibernation or a deferred start.
@MainActor @Suite struct AgentDrivenTabTests {
    func page() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration())
    }

    @Test func theMarkFollowsTheTabToItsNextPage() {
        let cache = TabContentCache(daemon: DaemonService())
        let first = page()
        cache.install(first, for: "tab")
        cache.markAgentDriven("tab")
        #expect(first.commands == [.markAgentDriven])

        let next = page()
        cache.swapPage("tab", with: next)
        #expect(next.commands.contains(.markAgentDriven))

        let other = page()
        cache.install(other, for: "other")
        #expect(!other.commands.contains(.markAgentDriven), "only the tab the agent drove")
    }

    @Test func aClosedTabForgetsTheMark() {
        let cache = TabContentCache(daemon: DaemonService())
        cache.install(page(), for: "tab")
        cache.markAgentDriven("tab")
        cache.release("tab")
        #expect(cache.agentDrivenTabs.isEmpty)
    }

    func login(_ kind: BrowserEngineKind = .cef) -> MockBrowserTab {
        MockBrowserEngine(kind: kind).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/login")))
    }

    func popupParent() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A page Chromium may already have filled reloads before the agent's
    /// first script, and so does a popup the tab opened (its script can
    /// reach it); a page marked before has nothing to clear.
    @Test func theFirstTouchReloadsPagesThatMayHoldAFilledPassword() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.popups.ordersPanelsIn = false
        let tab = login()
        services.cache.install(tab, for: "tab")
        let popup = login()
        services.popups.open(popup, request: BrowserPopupRequest(), over: popupParent(), openerKey: "tab")
        defer { services.popups.closeAll() }

        let stale = AppCompatBrowser.markAgentDriven("tab", services: services)
        #expect(tab.isAgentDriven && popup.isAgentDriven)
        #expect(stale.count == 2)
        #expect(throws: ControlError.self) { try AppCompatBrowser.reloadStale(stale, page: tab, for: .evaluate("1")) }
        #expect(tab.commands.contains(.reload) && popup.commands.contains(.reload))

        #expect(AppCompatBrowser.markAgentDriven("tab", services: services).isEmpty, "only the first touch")
    }

    /// Navigating away would keep the value in the back/forward cache, so it
    /// retries too; `reload` reloads the page itself, once.
    @Test func onlyReloadAndStateGoOnAtTheFirstTouch() throws {
        for operation in [CompatBrowserOperation.navigate("https://example.com"), .back, .forward, .evaluate("1")] {
            #expect(throws: ControlError.self) { try AppCompatBrowser.reloadStale([login()], page: login(), for: operation) }
        }
        let page = login()
        try AppCompatBrowser.reloadStale([page], page: page, for: .reload)
        #expect(!page.commands.contains(.reload), "the operation reloads it")
        try AppCompatBrowser.reloadStale([page], page: page, for: .state)
        #expect(page.commands.contains(.reload))
        try AppCompatBrowser.reloadStale([], page: page, for: .evaluate("1"))
    }

    /// WebKit has no saved-password autofill, and a blank page holds nothing.
    @Test func onlyChromiumWebPagesReload() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.cache.install(login(.webkit), for: "webkit")
        #expect(AppCompatBrowser.markAgentDriven("webkit", services: services).isEmpty)
        services.cache.install(page(), for: "blank")
        #expect(AppCompatBrowser.markAgentDriven("blank", services: services).isEmpty)
    }

    /// A popup an agent-driven popup opens is marked too, at any depth.
    @Test func aPopupsPopupIsMarked() throws {
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        defer { panels.closeAll() }
        let first = login()
        panels.open(first, request: BrowserPopupRequest(), over: popupParent(), openerKey: "tab")
        first.markAgentDriven()
        let second = login()
        #expect(panels.handle(first, .openPopup(second, BrowserPopupRequest())))
        #expect(second.isAgentDriven)
        #expect(panels.pages(openedBy: "tab").count == 2)
    }
}
