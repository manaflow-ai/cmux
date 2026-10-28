import AppKit
@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// Behavior audit 4, P8: what a Chromium Host's end keeps and how its tabs come back. The host is Chromium's
/// browser process, so its end takes every Chromium tab's page; cmux keeps each tab, its address, title and Back
/// list, says on an incognito tab's crash page that its sign-ins and site data are gone, and offers Reload All
/// Tabs. Against the suite's spy remote shim and reporting supervisor.
extension CEFRuntimeHostExitTests {
    /// The host's end takes the tab's Chromium back/forward list with it (Chromium kept it, cmux only mirrored
    /// it), but cmux keeps the entries it last saw: the Reload on the next host loads the page with those
    /// entries as its Back list, as Chrome's session restore gives a crashed tab its entries. An incognito tab
    /// too: its entries were only in memory, and cmux's copy outlives the host.
    @Test func aReloadAfterTheHostEndedKeepsTheTabsBackForwardEntries() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime(forkAPI: CEFTab.backForwardListForkAPI)
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1, offTheRecord: true)
        let first = URL(string: "https://example.com/a")!, second = URL(string: "https://example.com/b")!
        HostWire.state.withLock {
            $0.navigationEntries[1] = #"{"entries":[{"url":"https://example.com/a","title":"A"},{"url":"https://example.com/b","title":"B"}],"current":1}"#
        }
        tab.load(second)
        runtime.handle(.address(browser: 1, url: second.absoluteString))
        runtime.handle(.loadingState(browser: 1, loading: false, canGoBack: true, canGoForward: false))
        #expect(tab.navigationList()?.entries.map(\.url) == [first, second])

        supervisor.onHostEnded?(Self.hostKilled)
        tab.reload()
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        for _ in 0..<1_000 where tab.state.processExit != nil { await Task.yield() }
        #expect(tab.state.processExit == nil, "the page did not start loading again")
        runtime.register(tab, browser: 11)

        #expect(tab.navigationList()?.entries.map(\.url) == [first, second], "the host's end wiped the tab's Back list")
        #expect(tab.state.canGoBack, "Back is not offered after the Reload")
    }

    /// The host end's crash page offers Reload All Tabs: every shown tab the end left reloads on one new host,
    /// and a hidden one keeps its mark and reloads when it shows, as Chrome loads a discarded tab when it is
    /// selected. Without a registry route the button runs the runtime's own path.
    @Test func reloadAllTabsReloadsTheShownTabsNowAndTheHiddenOnesWhenTheyShow() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let shown = [Self.tab(runtime, browser: 1), Self.tab(runtime, browser: 2)]
        let hidden = Self.tab(runtime, browser: 3)
        // In the routing table, as the panes `CEFRuntime.host(for:)` makes are.
        for tab in shown + [hidden] {
            runtime.hosts[tab.host.key] = tab.host
            tab.load(Self.page)
        }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        for tab in shown { tab.host.present(tab, in: container) }
        let (status, area) = Self.statusViews(showing: shown[0])
        defer { withExtendedLifetime(area) {} }

        supervisor.onHostEnded?(Self.hostKilled)
        #expect(runtime.tabsTheHostEndLeft.count == 3)
        #if DEBUG
        #expect(status.goneView.debugText.contains(Strings.pageGoneReloadAllTabs), "the host end's crash page has no Reload All Tabs")
        status.goneView.pressReloadAll()
        #else
        runtime.reloadTabsTheHostEndLeft()
        #endif
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        for _ in 0..<1_000 where shown.contains(where: { $0.state.processExit != nil }) { await Task.yield() }

        #expect(supervisor.asked == 2, "the tabs' Reloads did not share one new host")
        #expect(shown.allSatisfy { $0.state.processExit == nil }, "a shown tab kept its crash page")
        #expect(hidden.state.processExit == Self.hostKilled && hidden.reloadWhenShown, "a hidden tab loaded before it showed")
        #expect(HostWire.state.withLock { $0.deadWireOps } == 0, "an op went to the dead host's wire")
    }

    /// A renderer's end shows no Reload All Tabs: only that page ended.
    @Test func aRendererEndsCrashPageHasNoReloadAllTabs() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tab = Self.tab(runtime, browser: 1)
        let (status, area) = Self.statusViews(showing: tab)
        defer { withExtendedLifetime(area) {} }
        runtime.handle(.renderTerminated(browser: 1, status: 2, code: Int(SIGSEGV), text: "", end: .first))
        #expect(!status.goneView.isHidden)
        #if DEBUG
        #expect(!status.goneView.debugText.contains(Strings.pageGoneReloadAllTabs))
        #endif
        #expect(runtime.tabsTheHostEndLeft.isEmpty)
    }

    /// An incognito tab's sign-ins and site data lived only in the dead host's memory: its crash page says
    /// they are gone, which a normal tab's (whose data is on disk) does not.
    @Test func anIncognitoTabsCrashPageSaysItsSiteDataIsGone() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let normal = Self.tab(runtime, browser: 1)
        let incognito = Self.tab(runtime, browser: 2, offTheRecord: true)
        let (normalStatus, normalArea) = Self.statusViews(showing: normal)
        let (incognitoStatus, incognitoArea) = Self.statusViews(showing: incognito)
        defer { withExtendedLifetime((normalArea, incognitoArea)) {} }

        supervisor.onHostEnded?(Self.hostKilled)

        #expect(!normalStatus.goneView.isHidden && !incognitoStatus.goneView.isHidden)
        #if DEBUG
        #expect(incognitoStatus.goneView.debugText != normalStatus.goneView.debugText,
                "the incognito tab's crash page does not say its sign-ins and site data are gone")
        #endif
    }
}

/// The addresses whose saved navigation the runtime asked for.
@MainActor final class AskedURLs {
    var urls: [URL] = []
}

/// Closes the tab when it asks to close, as the app's tab owner does.
@MainActor final class TabCloser: BrowserTabDelegate {
    private(set) var closes = 0

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        guard case .close = intent else { return }
        closes += 1
        (tab as? CEFTab)?.close()
    }
}
