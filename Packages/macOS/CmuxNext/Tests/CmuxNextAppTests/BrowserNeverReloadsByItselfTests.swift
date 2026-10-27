import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHibernation
@testable import CmuxNextSettings
import Foundation
import Testing

/// "why does cmux-next's browser keep refreshing and reloading? this happened before with austin
/// using google maps" (Leo, 2026-10-26). A hidden page was discarded (after 30 minutes hidden, or
/// 10 seconds under memory pressure) and reloaded from its saved history when shown: a GitHub
/// settings page came back at the sign-in page, a map lost its place. A page never reloads unless
/// the person asks: by default hidden pages only freeze (they keep their state) and nothing is
/// discarded on its own; a timeout written to cmux.json still discards, as the person asked.
@Suite struct BrowserNeverReloadsByItselfPlanTests {
    private func page(_ key: String, minutes: Double) -> HibernationPlanner.Candidate {
        HibernationPlanner.Candidate(key: key, hiddenFor: minutes * 60)
    }

    /// No `browser.hibernation` in cmux.json: no hidden page is discarded, however long it has been
    /// hidden and at every memory pressure, and no deadline is armed for one.
    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func theDefaultNeverDiscards(pressure: MemoryPressureLevel) {
        let plan = HibernationPlanner.plan(.fallback, pressure: pressure, candidates: [
            page("github-settings", minutes: 600), page("maps", minutes: 45), page("docs", minutes: 1),
        ])
        #expect(plan.due.isEmpty, "a hidden page was discarded by default (it reloads when shown)")
        #expect(plan.nextCheck == nil)
        #expect(plan.exemptions == ["github-settings": .keepsState, "maps": .keepsState, "docs": .keepsState])
    }

    /// A page's own reason to stay is still the one reported (`debug.surfaces`).
    @Test func aPinnedPageReportsPinned() {
        var pinned = page("pinned", minutes: 90)
        pinned.isPinned = true
        let plan = HibernationPlanner.plan(.fallback, pressure: .critical, candidates: [pinned])
        #expect(plan.exemptions["pinned"] == .pinned)
    }

    /// Freezing (power, not memory: the page keeps its state) still applies by default.
    @Test func theDefaultStillFreezes() {
        let plan = HibernationPlanner.freezePlan(.fallback, candidates: [page("maps", minutes: 1)])
        #expect(plan.due == ["maps"])
    }

    /// A timeout the person set still discards, as before.
    @Test func anExplicitTimeoutStillDiscards() throws {
        let (setting, diagnostics) = BrowserHibernationSetting.parse(.object(["browser": .object(["hibernation": .string("moderate")])]))
        #expect(diagnostics.isEmpty)
        #expect(setting.discardsAutomatically)
        let plan = HibernationPlanner.plan(setting, pressure: .normal, candidates: [page("old", minutes: 31)])
        #expect(plan.due == ["old"])
    }

    @Test func onlyAWrittenSettingOptsIn() {
        #expect(!BrowserHibernationSetting.fallback.discardsAutomatically)
        #expect(!BrowserHibernationSetting.parse(.object([:])).0.discardsAutomatically)
        #expect(!BrowserHibernationSetting.parse(.object(["browser": .object(["freezeHiddenTabs": .number(60)])])).0.discardsAutomatically)
        #expect(!BrowserHibernationSetting.parse(.object(["browser": .object(["hibernation": .string("sometimes")])])).0.discardsAutomatically)
        #expect(BrowserHibernationSetting.parse(.object(["browser": .object(["hibernation": .number(45)])])).0.discardsAutomatically)
        #expect(BrowserHibernationSetting.parse(.object(["browser": .object(["hibernation": .string("aggressive")])])).0.discardsAutomatically)
    }
}

/// Real WebKit pages through the app's tab content cache and hibernation under critical memory
/// pressure (where a hidden page used to be discarded after 10 seconds): switching tabs,
/// workspaces and panes (a page hidden by one presenter and shown by another) never reloads it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserNeverReloadsByItselfTests {
    @Test func switchingAwayAndBackNeverReloadsAPage() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        // The default: no `browser.hibernation` in cmux.json.
        rig.hibernation.apply(.fallback)
        rig.hibernation.pressureDidChange(.critical)
        let page = try await rig.page("signed-in", body: "<input id='q'><script>window.loadedAt = performance.timeOrigin;</script>")
        let loadedAt = try await page.evaluate("window.loadedAt", world: .page, gesture: .agent)
        _ = try await page.evaluate("window.mark = 'still here'; true", world: .page, gesture: .agent)
        let key = try await rig.hide(page)

        // Past the 10 s under critical pressure after which a hidden page used to be discarded.
        try await Task.sleep(for: .seconds(12))
        rig.hibernation.replan()
        #expect(!rig.isHibernated(key), "a hidden page was discarded by default (it reloads when shown)")
        #expect(rig.exemption(key) == .keepsState)

        // Tab and workspace switches (the same pane shows and hides it), then a pane move (another
        // pane shows it).
        let other = HiddenPageHibernationTests.Pane()
        for presenter in [rig.pane, rig.pane, other, rig.pane] {
            rig.services.cache.present(key, by: presenter, presence: .visible)
            #expect(rig.services.cache.phase(of: key) == .mountedVisible)
            rig.services.cache.withdraw(key, by: presenter)
        }
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        let shown = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        #expect(shown === page, "the page was recreated")
        #expect(try await shown.evaluate("window.loadedAt", world: .page, gesture: .agent) == loadedAt, "the page loaded again")
        #expect(try await shown.evaluate("window.mark", world: .page, gesture: .agent) == .string("still here"), "the page lost its state")
        rig.services.cache.withdraw(key, by: rig.pane)
    }

    /// A page whose content process ended keeps its crash notice: even with a timeout set and
    /// under critical pressure it is never discarded (its restore would load it by itself).
    @Test func aCrashedHiddenPageIsNeverDiscarded() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("crashed", body: "<p>gone</p>")
        page.webViewWebContentProcessDidTerminate(page.webView)
        try #require(page.state.processExit != nil)
        let key = try await rig.hide(page)
        try await rig.until("the page was kept") { rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .unsupported)
        #expect(!rig.isHibernated(key), "a crashed page was discarded")
        #expect(rig.services.cache.browsers[key]?.tab === page)
    }
}
