import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHibernation
@testable import CmuxNextSettings
import Foundation
import Testing

/// Leo, 2026-11-14, approving process-sharing row 4 ("4 yes"): hidden browser tabs are discarded by
/// default and reloaded when shown, keeping tabs that play audio, have an unsaved form, or are pinned.
/// Before, with no `browser.hibernation` in cmux.json, hidden pages only froze and kept their
/// renderers (Leo, 2026-10-26: "why does cmux-next's browser keep refreshing and reloading?" made
/// that the default; the 2026-11-14 approval takes it back for browser tabs). The rules are Rust
/// (cmux-tui/crates/cmux-tab-discard, with their own tests); these check the app asks them.
@Suite struct BrowserNeverReloadsByItselfPlanTests {
    private func page(_ key: String, minutes: Double) -> HibernationPlanner.Candidate {
        HibernationPlanner.Candidate(key: key, hiddenFor: minutes * 60)
    }

    /// No `browser.hibernation` in cmux.json: a hidden page past the 30 minute timeout is discarded,
    /// and under memory pressure one hidden past the pace's minimum goes too. Red before: unset kept
    /// every page (`keeps_state`).
    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func theDefaultDiscardsAHiddenTabPastTheTimeout(pressure: MemoryPressureLevel) {
        let plan = HibernationPlanner.plan(.unset, pressure: pressure, candidates: [page("github-settings", minutes: 600)])
        #expect(plan.due == ["github-settings"], "a hidden tab past the timeout was kept by default")
        #expect(plan.exemptions.isEmpty)
    }

    /// A pinned tab is kept by default, at every pressure, and reports why (`debug.surfaces`).
    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func aPinnedTabIsKept(pressure: MemoryPressureLevel) {
        var pinned = page("pinned", minutes: 90)
        pinned.isPinned = true
        let plan = HibernationPlanner.plan(.unset, pressure: pressure, candidates: [pinned])
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions["pinned"] == .pinned)
    }

    /// A tab playing audio or holding the person's unsaved form input is kept by its probe, at every pressure.
    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func audioAndUnsavedFormInputKeepTheTab(pressure: MemoryPressureLevel) {
        #expect(PageProbe(playingMedia: true).keepReason("plan-audio", pressure: pressure, showsFormSubmission: false) == .audio)
        #expect(PageProbe(editedForm: true).keepReason("plan-form", pressure: pressure, showsFormSubmission: false) == .formInput)
        #expect(PageProbe(beforeUnload: true).keepReason("plan-unload", pressure: pressure, showsFormSubmission: false) == .beforeUnload)
        #expect(PageProbe().keepReason("plan-plain", pressure: pressure, showsFormSubmission: false) == nil)
    }

    /// "Never" still turns it off at every pressure.
    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func offNeverDiscards(pressure: MemoryPressureLevel) {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .off), pressure: pressure, candidates: [page("old", minutes: 600)])
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions["old"] == .disabled)
    }

    /// Freezing (power, not memory: the page keeps its state) still applies by default.
    @Test func theDefaultStillFreezes() {
        let plan = HibernationPlanner.freezePlan(.unset, candidates: [page("maps", minutes: 1)])
        #expect(plan.due == ["maps"])
    }

    /// Whether cmux.json writes the setting is still known (hidden chat pages follow only a written one).
    @Test func onlyAWrittenSettingIsWritten() {
        #expect(!BrowserHibernationSetting.unset.isWritten)
        #expect(!BrowserHibernationSetting.parse(.object([:])).0.isWritten)
        #expect(BrowserHibernationSetting.parse(.object(["browser": .object(["hibernation": .number(45)])])).0.isWritten)
        #expect(BrowserHibernationSetting.unset.hiddenMinutes == 30)
    }
}

/// Real WebKit pages through the app's tab content cache and hibernation, with no
/// `browser.hibernation` in cmux.json.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserNeverReloadsByItselfTests {
    /// Switching tabs, workspaces and panes (a page hidden by one presenter and shown by another)
    /// well inside the timeout never reloads a page: only a page hidden past it is discarded.
    @Test func switchingAwayAndBackNeverReloadsAPage() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.apply(.unset)
        rig.hibernation.pressureDidChange(.normal)
        let page = try await rig.page("signed-in", body: "<input id='q'><script>window.loadedAt = performance.timeOrigin;</script>")
        let loadedAt = try await page.evaluate("window.loadedAt", world: .page, gesture: .agent)
        _ = try await page.evaluate("window.mark = 'still here'; true", world: .page, gesture: .agent)
        let key = try await rig.hide(page)
        rig.hibernation.replan()
        #expect(!rig.isHibernated(key), "a page hidden a moment was discarded")

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

    /// By default a hidden page past the pace's minimum under critical memory pressure is discarded
    /// (its engine page closes), and showing it again reloads it at its URL. Red before: unset kept it
    /// (`keeps_state`).
    @Test func theDefaultDiscardsAHiddenPageAndShowingItReloadsItAtItsURL() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.apply(.unset)
        rig.hibernation.pressureDidChange(.critical)
        let page = try await rig.page("plain", body: "<p>plain</p><script>window.loadedAt = performance.timeOrigin;</script>")
        let url = try #require(page.state.url)
        let loadedAt = try await page.evaluate("window.loadedAt", world: .page, gesture: .agent)
        let key = try await rig.hide(page)
        try await rig.until("the default discarded the hidden page") { rig.isHibernated(key) }

        rig.hibernation.pressureDidChange(.normal)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the shown page is back") { rig.services.cache.browsers[key]?.tab is WebKitTab }
        let back = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        try await rig.until("the shown page loaded") {
            (try? await back.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string("plain")
        }
        #expect(back.state.url == url, "the page came back elsewhere")
        #expect(try await back.evaluate("window.loadedAt", world: .page, gesture: .agent) != loadedAt, "the page did not reload")
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

    /// An agent takes the page's lease while the discard probe takes its picture (the replan the
    /// lease starts skips a probing page): the page stays, even for Hibernate Tab.
    @Test func aLeaseTakenDuringTheProbeKeepsThePage() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.pressureDidChange(.normal)
        let page = try await rig.page("leased", body: "<p>driven</p>")
        let key = page.id.rawValue
        let hibernation = rig.hibernation
        let captured = Flag()
        hibernation.capture = { [hibernation] _ in
            await MainActor.run {
                captured.isSet = true
                hibernation.noteLease(key, held: true)
            }
            return nil
        }
        _ = try await rig.hide(page)
        #expect(hibernation.hibernateNow(key) == nil)
        try await rig.until("the probe ended") { captured.isSet && !hibernation.probing.contains(key) }
        #expect(!rig.isHibernated(key), "a page an agent holds was discarded")
        #expect(rig.exemption(key) == .agentLease)
        #expect(rig.services.cache.browsers[key]?.tab === page)
        // Asked again while the lease is held: refused at once.
        #expect(hibernation.hibernateNow(key) == .agentLease)
        hibernation.noteLease(key, held: false)
    }

    /// Shown and hidden again while its discard probe ran: the probe is dropped, and the page it
    /// thawed freezes again (before, the hide's replan skipped the probing page and the dropped
    /// probe planned nothing, so it stayed thawed until some later event).
    @Test func aPageShownAndHiddenDuringItsProbeFreezesAgain() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: 0.2))
        rig.hibernation.pressureDidChange(.normal)
        let recorder = NeighborTabsWakeTests.Recorder()
        let page = try await rig.page("flipped", body: "<p>flip</p>")
        let key = page.id.rawValue
        rig.hibernation.freezer = { tab in tab.id.rawValue == key ? recorder : nil }
        let hibernation = rig.hibernation
        let cache = rig.services.cache
        let pane = rig.pane
        let flipped = Flag()
        hibernation.capture = { [cache, pane] _ in
            await MainActor.run {
                guard !flipped.isSet else { return }
                flipped.isSet = true
                cache.present(key, by: pane, presence: .visible)
                cache.withdraw(key, by: pane)
            }
            return nil
        }
        _ = try await rig.hide(page)
        try await rig.until("the page froze") { hibernation.frozen.contains(key) }
        #expect(hibernation.hibernateNow(key) == nil)
        try await rig.until("the probe was dropped") { flipped.isSet && !hibernation.probing.contains(key) }
        #expect(!rig.isHibernated(key))
        #expect(cache.phase(of: key) == .mountedHidden)
        try await rig.until("the thawed page froze again") { hibernation.frozen.contains(key) }
        #expect(recorder.calls.suffix(2) == [false, true])
    }

    /// The same for the freeze probe: shown and hidden again while it asks the page, the page
    /// freezes after its new hidden delay instead of staying awake.
    @Test func aPageShownAndHiddenDuringItsFreezeProbeFreezesAgain() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: 0.2))
        rig.hibernation.pressureDidChange(.normal)
        let recorder = NeighborTabsWakeTests.Recorder()
        var freezes = false
        let page = try await rig.page("freeze-flipped", body: "<p>flip</p>")
        let key = page.id.rawValue
        // No freezer yet: the hide plans no freeze.
        rig.hibernation.freezer = { tab in freezes && tab.id.rawValue == key ? recorder : nil }
        _ = try await rig.hide(page)
        try await Task.sleep(for: .milliseconds(300))
        freezes = true
        // The plan starts the freeze probe; the show and hide land before it answers.
        rig.hibernation.replan()
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        rig.services.cache.withdraw(key, by: rig.pane)
        #expect(!rig.hibernation.frozen.contains(key))
        try await rig.until("the page froze after the stale probe") { rig.hibernation.frozen.contains(key) }
        #expect(recorder.calls.last == true)
    }

    /// A flag a test's capture seam sets on the main actor.
    @MainActor final class Flag: Sendable {
        var isSet = false
    }
}
