import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
import CmuxNextHibernation
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Hover preload, live (plans/cmux-next/hover-preload-DESIGN.md): the pointer resting on a tab or a
/// workspace row wakes the pages that click would show, and a pointer that only passes wakes nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HoverWakeTests {
    typealias Rig = NeighborTabsWakeTests.Rig

    /// The hover dwell on a clock the test moves (the hibernation's hover gates sleep on it): the pointer
    /// moves exactly one frame apart and rests exactly the dwell, whatever the runner's load.
    struct DwellClock {
        let clock = ManualClock()
        let start = ContinuousClock.now

        @MainActor func drive(_ hibernation: BrowserHibernation) {
            let clock = clock, start = start
            let now: @Sendable () -> ContinuousClock.Instant = { start + clock.now.offset }
            hibernation.tabHover = HoverWakeGate(owner: "BrowserHoverTab", clock: clock, now: now) { [weak hibernation] in
                hibernation?.hoverIntent($0)
            }
            hibernation.workspaceHover = HoverWakeGate(owner: "BrowserHoverWorkspace", clock: clock, now: now) { [weak hibernation] in
                hibernation?.hoverIntent($0)
            }
        }

        /// The first hover armed the dwell timer: returns once it sleeps on the clock.
        func armed() async throws { try await clock.waitForSleeper() }

        /// One frame passes before the pointer moves again. A frame that reaches the dwell timer's
        /// deadline fires it on a pointer that moved within the dwell, so it sleeps again for the time
        /// left: returns once it does, so the next frame moves that deadline too.
        func frame(_ length: Duration) async throws {
            let reached = clock.sleeperDeadlines.contains { $0 <= clock.now.advanced(by: length) }
            clock.advance(by: length)
            if reached { try await clock.waitForSleeper() }
        }

        /// The pointer rests for the dwell on what it last moved to: the timer armed for it fires.
        func rest() async throws {
            try await clock.waitForSleeper()
            clock.advance(by: BrowserHibernation.hoverDwellDelay)
        }
    }

    /// The pointer sweeps across three frozen far tabs at 120 Hz (one tab per 8 ms frame) and leaves the
    /// strip: no page thaws, none is kept awake, and nothing counts as prewarmed. A rest on a fourth tab
    /// after it wakes that tab: its intent comes after the sweep's timer fired, so the sweep had its say.
    @Test func aSweepAcrossTheStripWakesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let dwell = DwellClock()
        dwell.drive(rig.hibernation)
        let keys = try await rig.pages(["a", "b", "c", "d", "e", "f", "g"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys) // b and g are neighbors and thaw
        let far = [keys[2], keys[3], keys[4]]
        let rested = keys[5]
        let prewarmed = rig.hibernation.prewarmedCount

        for (index, key) in far.enumerated() {
            rig.hibernation.noteHover(key)
            if index == 0 { try await dwell.armed() }
            try await dwell.frame(.milliseconds(8))
        }
        rig.hibernation.noteHover(nil)
        dwell.clock.advance(by: BrowserHibernation.hoverDwellDelay) // past the dwell with the pointer off the strip

        rig.hibernation.noteHover(rested)
        try await dwell.rest()
        try await rig.until("the tab the pointer rested on thaws") { !rig.hibernation.frozen.contains(rested) }
        let woken = far.filter { !rig.hibernation.frozen.contains($0) }
        #expect(woken.isEmpty, "tabs the pointer only crossed woke: \(woken)")
        #expect(rig.hibernation.prewarmedCount - prewarmed == 1, "only the rested tab counts as prewarmed")
    }

    /// (a) The pointer sweeps over 200 sidebar rows at 120 Hz and leaves: no workspace is asked for its
    /// pages (the dwell never held), and each row change costs the main thread one lock write.
    @Test func aSweepOverTheSidebarWakesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let dwell = DwellClock()
        dwell.drive(rig.hibernation)
        var asked: [String] = []
        rig.hibernation.workspaceTabs = { workspace, _ in
            asked.append(workspace)
            return []
        }
        let clock = ContinuousClock()
        var slowest: Duration = .zero
        for index in 0..<200 {
            let cost = clock.measure { rig.hibernation.noteWorkspaceHover("w\(index)", window: "win") }
            slowest = max(slowest, cost)
            if index == 0 { try await dwell.armed() }
            try await dwell.frame(.microseconds(8_333))
        }
        rig.hibernation.noteWorkspaceHover(nil, window: "win")
        dwell.clock.advance(by: BrowserHibernation.hoverDwellDelay) // past the dwell with the pointer off the sidebar

        // A rest on one more row asks its workspace: its intent comes after the sweep's timer fired.
        rig.hibernation.noteWorkspaceHover("rested", window: "win")
        try await dwell.rest()
        try await rig.until("the rested row asks its workspace") { !asked.isEmpty }
        #expect(asked == ["rested"], "a sweep asked workspaces for their pages: \(asked)")
        #expect(slowest < .milliseconds(2), "one row change cost the main thread \(slowest)")
    }

    /// (b, c) The pointer rests on a workspace row whose three shown pages its workspace's hibernation
    /// discarded: two restore in the background (the budget), the third waits for the click. When the
    /// grace ends and nobody showed them, they are discarded again.
    @Test func aRestingPointerOnAWorkspaceRowWakesItsPagesAndTheGraceSendsThemBack() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false, wakesOnHover: true))
        let keys = try await rig.pages(["a", "b", "c"])
        for key in keys { #expect(rig.hibernation.hibernateForWorkspace(key) == nil) }
        try await rig.until("the workspace's pages hibernate") { keys.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        var asked: [String] = []
        rig.hibernation.workspaceTabs = { workspace, window in
            asked.append("\(window)/\(workspace)")
            return workspace == "w" ? keys : []
        }

        rig.hibernation.noteWorkspaceHover("w", window: "win")
        func live(_ key: String) -> Bool {
            rig.services.cache.phase(of: key) == .mountedHidden && !(rig.services.cache.browsers[key]?.tab is HibernatedBrowserTab)
        }
        try await rig.until("two pages restore while hidden") { keys.filter(live).count == 2 }
        #expect(asked == ["win/w"])
        #expect(rig.services.cache.phase(of: keys[2]) == .hibernated, "one intent woke more than its budget")
        #expect(Set(rig.hibernation.hoverRestores.pages) == Set(keys.prefix(2)))

        let later = ContinuousClock.now + .seconds(BrowserHibernation.hoverGrace + 1)
        rig.hibernation.now = { later }
        rig.hibernation.replan()
        try await rig.until("the woken pages hibernate again") { keys.prefix(2).allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        #expect(rig.hibernation.hoverRestores.pages.isEmpty)
    }

    /// A page the person hibernated (Hibernate Tab) does not restore on a workspace row's hover.
    @Test func aWorkspaceHoverLeavesThePersonsHibernatedPageAlone() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, wakesOnHover: true))
        let keys = try await rig.pages(["a"])
        #expect(rig.hibernation.hibernateNow(keys[0]) == nil)
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: keys[0]) == .hibernated }
        var asked = false
        rig.hibernation.workspaceTabs = { _, _ in
            asked = true
            return keys
        }
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        // `asked` is set inside the intent, which restores (or not) before it returns on the main actor.
        try await rig.until("the hover intent fires") { asked }
        #expect(rig.services.cache.phase(of: keys[0]) == .hibernated)
        #expect(rig.hibernation.hoverRestores.pages.isEmpty)
    }

    /// The person's Hibernate Workspace: its pages restore only when shown, never on a hover.
    @Test func aWorkspaceThePersonHibernatedDoesNotWakeOnHover() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false, wakesOnHover: true))
        let keys = try await rig.pages(["a", "b"])
        for key in keys { #expect(rig.hibernation.hibernateForWorkspace(key, byPerson: true) == nil) }
        try await rig.until("the workspace's pages hibernate") { keys.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        var asked = false
        rig.hibernation.workspaceTabs = { _, _ in
            asked = true
            return keys
        }
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        // `asked` is set inside the intent, which restores (or not) before it returns on the main actor.
        try await rig.until("the hover intent fires") { asked }
        for key in keys { #expect(rig.services.cache.phase(of: key) == .hibernated, "a page the person hibernated reloaded on hover") }
    }

    /// A newer intent replaces the older: resting on a second row sends the first row's woken pages back,
    /// so at most `HoverWakeBudget.inFlight` hover-restored pages live at once.
    @Test func aNewerWorkspaceIntentSendsTheOlderOnesPagesBack() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false, wakesOnHover: true))
        let keys = try await rig.pages(["a", "b", "c", "d"])
        for key in keys { #expect(rig.hibernation.hibernateForWorkspace(key) == nil) }
        try await rig.until("the pages hibernate") { keys.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        rig.hibernation.workspaceTabs = { workspace, _ in workspace == "w1" ? Array(keys.prefix(2)) : Array(keys.suffix(2)) }
        func live(_ key: String) -> Bool {
            rig.services.cache.phase(of: key) == .mountedHidden && !(rig.services.cache.browsers[key]?.tab is HibernatedBrowserTab)
        }

        rig.hibernation.noteWorkspaceHover("w1", window: "win")
        try await rig.until("w1's pages restore") { keys.prefix(2).allSatisfy(live) }
        rig.hibernation.noteWorkspaceHover("w2", window: "win")
        try await rig.until("w2's pages restore") { keys.suffix(2).allSatisfy(live) }
        try await rig.until("w1's pages go back") { keys.prefix(2).allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        #expect(rig.hibernation.hoverRestores.pages == Array(keys.suffix(2)))
    }

    /// cmux-ad m44: hover preload ships off. With the default settings a rest on a workspace row past the dwell wakes
    /// none of its hibernated pages (run 08e33948 at 120 Hz: cold click p50 18.6-31 ms worse with it on).
    @Test func hoverPreloadIsOffByDefault() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false))
        let keys = try await rig.pages(["a", "b"])
        for key in keys { #expect(rig.hibernation.hibernateForWorkspace(key) == nil) }
        try await rig.until("the workspace's pages hibernate") { keys.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        var asked = 0
        rig.hibernation.workspaceTabs = { _, _ in
            asked += 1
            return keys
        }
        #expect(rig.hibernation.hoverBudget.pages == 0, "the default settings let a hover wake pages")
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        // The dwell held: the intent the gate delivers then wakes nothing either.
        rig.hibernation.hoverIntent(.workspace("w", window: "win"))
        #expect(asked == 0, "a hover asked a workspace for its pages with hover preload off")
        for key in keys { #expect(rig.services.cache.phase(of: key) == .hibernated, "a hover woke a page with hover preload off") }
    }

    /// `browser.keepNeighborTabsAwake` 0: the person asked that no hidden page be kept awake early, so a
    /// hover wakes nothing either.
    @Test func keepNoNeighborTabsAwakeTurnsHoverWakesOff() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var setting = rig.hibernation.setting
        setting.wakesOnHover = true
        setting.neighborRadius = 0
        rig.hibernation.apply(setting)
        let keys = try await rig.pages(["a", "b", "c"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        #expect(rig.hibernation.hoverBudget.pages == 0)
        rig.hibernation.noteHover(keys[1])
        // The dwell held: the intent the gate delivers wakes nothing.
        rig.hibernation.hoverIntent(.tab(keys[1]))
        #expect(rig.hibernation.frozen.contains(keys[1]))
    }

    /// A hover-restored page past its grace, then the person turns `browser.hibernation` off: the page
    /// stops being a hover restore at once, and no replan probes it again and again (review of #36637).
    @Test func turningHibernationOffEndsTheGraceDiscardWithoutAProbeLoop() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, wakesOnHover: true))
        let keys = try await rig.pages(["a"])
        #expect(rig.hibernation.hibernateForWorkspace(keys[0]) == nil)
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: keys[0]) == .hibernated }
        rig.hibernation.workspaceTabs = { _, _ in keys }
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        try await rig.until("the hover restores it") {
            rig.services.cache.phase(of: keys[0]) == .mountedHidden && !(rig.services.cache.browsers[keys[0]]?.tab is HibernatedBrowserTab)
        }
        #expect(rig.hibernation.hoverRestores.contains(keys[0]))

        let later = ContinuousClock.now + .seconds(BrowserHibernation.hoverGrace + 1)
        rig.hibernation.now = { later }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .off, freezeSeconds: nil, wakesOnHover: true))
        #expect(!rig.hibernation.hoverRestores.contains(keys[0]), "a kept page is still a hover restore to send back")
        #expect(!rig.hibernation.probing.contains(keys[0]), "the grace discard probed a page no discard can take")
        // The next replans (the grace deadline's, a hide's) probe it no more: a probe starts inside replan.
        for _ in 0..<3 {
            rig.hibernation.replan()
            #expect(!rig.hibernation.probing.contains(keys[0]), "a later replan probed the kept page")
        }
        #expect(rig.services.cache.phase(of: keys[0]) == .mountedHidden)
    }
}
