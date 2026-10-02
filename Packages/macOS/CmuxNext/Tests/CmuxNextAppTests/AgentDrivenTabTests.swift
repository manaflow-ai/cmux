import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
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

    /// A page Chromium may already have filled leaves the cache at the
    /// agent's first touch (no later operation can reach its document while
    /// a new page loads), and the operation retries; popups are marked; a
    /// page marked before has nothing to clear.
    @Test func theFirstTouchRebuildsAPageThatMayHoldAFilledPassword() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.popups.ordersPanelsIn = false
        let tab = login()
        services.cache.install(tab, for: "tab")
        let popup = login()
        services.popups.open(popup, request: BrowserPopupRequest(), over: popupParent(), openerKey: "tab")
        defer { services.popups.closeAll() }

        let stale = AppCompatBrowser.markAgentDriven("tab", services: services)
        #expect(stale)
        #expect(tab.isAgentDriven && popup.isAgentDriven)
        #expect(throws: ControlError.self) {
            try AppCompatBrowser.rebuildStale(stale, tabID: "tab", for: .evaluate("1"), services: services)
        }
        #expect(services.cache.existingBrowser("tab") == nil)
        #expect(tab.isClosed)
        #expect(services.cache.agentDrivenTabs.contains("tab"), "the next page is marked when it installs")

        let next = login()
        services.cache.install(next, for: "tab")
        #expect(next.isAgentDriven)
        #expect(!AppCompatBrowser.markAgentDriven("tab", services: services), "only the first touch")
    }

    /// Every operation but `state` (no page content) retries on the new page.
    @Test func onlyStateGoesOnAtTheFirstTouch() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        for operation in [CompatBrowserOperation.navigate("https://example.com"), .back, .forward, .reload, .evaluate("1")] {
            services.cache.install(login(), for: "tab")
            #expect(throws: ControlError.self) { try AppCompatBrowser.rebuildStale(true, tabID: "tab", for: operation, services: services) }
        }
        services.cache.install(login(), for: "tab")
        try AppCompatBrowser.rebuildStale(true, tabID: "tab", for: .state, services: services)
        try AppCompatBrowser.rebuildStale(false, tabID: "tab", for: .evaluate("1"), services: services)
    }

    /// Every live Chromium page rebuilds, a blank one too (a page's
    /// `window.open()` tab shares its origin and keeps `window.opener`);
    /// WebKit has no saved-password autofill, and a placeholder no document.
    @Test func everyLiveChromiumPageRebuilds() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.cache.install(page(), for: "blank")
        #expect(AppCompatBrowser.markAgentDriven("blank", services: services))
        services.cache.install(login(.webkit), for: "webkit")
        #expect(!AppCompatBrowser.markAgentDriven("webkit", services: services))
        let deferred = DeferredBrowserTab(id: BrowserTabID(rawValue: "asleep"), engine: .cef, url: URL(string: "https://example.com"), title: nil)
        services.cache.install(deferred, for: "asleep")
        #expect(!AppCompatBrowser.markAgentDriven("asleep", services: services))
        #expect(services.cache.agentDrivenTabs.contains("asleep"), "its next page is marked")
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

    /// A tab the CLI, MCP or a script opens is marked before its page exists;
    /// one whose page came first is left to the first-touch rebuild.
    @Test func aTabAnAgentOpenedIsMarkedBeforeItsFirstPage() {
        let cache = TabContentCache(daemon: DaemonService())
        cache.markAgentDriven(surface: SurfaceID(rawValue: 7))
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 7), key: "agent")
        let first = page()
        cache.install(first, for: "agent")
        #expect(first.isAgentDriven)
        #expect(cache.agentDrivenSurfaces.isEmpty)

        cache.claimAgentDriven(surface: SurfaceID(rawValue: 8), key: "user")
        #expect(!cache.agentDrivenTabs.contains("user"), "only the surfaces an agent opened")

        cache.install(page(), for: "late")
        cache.markAgentDriven(surface: SurfaceID(rawValue: 9))
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 9), key: "late")
        #expect(!cache.agentDrivenTabs.contains("late"), "its page loaded unmarked: the first touch rebuilds it")
        #expect(cache.agentDrivenSurfaces.isEmpty)
    }
}
