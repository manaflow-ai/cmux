import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
import CmuxNextHibernation
import Foundation
import Testing

/// Hover preload, live (plans/cmux-next/hover-preload-DESIGN.md): the pointer resting on a tab or a
/// workspace row wakes the pages that click would show, and a pointer that only passes wakes nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HoverWakeTests {
    typealias Rig = NeighborTabsWakeTests.Rig

    /// The pointer sweeps across three frozen far tabs at 120 Hz (one tab per 8 ms frame) and leaves the
    /// strip: no page thaws, none is kept awake, and nothing counts as prewarmed.
    @Test func aSweepAcrossTheStripWakesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d", "e", "f"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys) // b and f are neighbors and thaw
        let far = [keys[2], keys[3], keys[4]]
        let prewarmed = rig.hibernation.prewarmedCount

        // A runner stall past the dwell between two moves is a real rest on that tab: counted, not failed.
        var stalls = 0
        var last = ContinuousClock.now
        for key in far {
            rig.hibernation.noteHover(key)
            try await Task.sleep(for: .milliseconds(8))
            if ContinuousClock.now - last >= .milliseconds(95) { stalls += 1 }
            last = .now
        }
        rig.hibernation.noteHover(nil)
        try await Task.sleep(for: .milliseconds(400))

        let woken = far.filter { !rig.hibernation.frozen.contains($0) }
        #expect(woken.count <= stalls, "tabs the pointer only crossed woke: \(woken.count), runner stalls: \(stalls)")
        #expect(rig.hibernation.prewarmedCount - prewarmed <= stalls)
    }

    /// (a) The pointer sweeps over 200 sidebar rows at 120 Hz and leaves: no workspace is asked for its
    /// pages (the dwell never held), and each row change costs the main thread one lock write.
    @Test func aSweepOverTheSidebarWakesNothing() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var asked = 0
        rig.hibernation.workspaceTabs = { _, _ in
            asked += 1
            return []
        }
        let clock = ContinuousClock()
        var stalls = 0
        var slowest: Duration = .zero
        var last = clock.now
        for index in 0..<200 {
            let now = clock.now
            if now - last >= .milliseconds(95) { stalls += 1 } // the test runner itself stalled past the dwell
            last = now
            let cost = clock.measure { rig.hibernation.noteWorkspaceHover("w\(index)", window: "win") }
            slowest = max(slowest, cost)
            try await Task.sleep(for: .microseconds(8_333))
        }
        rig.hibernation.noteWorkspaceHover(nil, window: "win")
        try await Task.sleep(for: .milliseconds(400))
        #expect(asked <= stalls, "a sweep asked \(asked) workspaces for their pages")
        #expect(slowest < .milliseconds(2), "one row change cost the main thread \(slowest)")
    }

    /// (b, c) The pointer rests on a workspace row whose three shown pages its workspace's hibernation
    /// discarded: two restore in the background (the budget), the third waits for the click. When the
    /// grace ends and nobody showed them, they are discarded again.
    @Test func aRestingPointerOnAWorkspaceRowWakesItsPagesAndTheGraceSendsThemBack() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false))
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
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil))
        let keys = try await rig.pages(["a"])
        #expect(rig.hibernation.hibernateNow(keys[0]) == nil)
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: keys[0]) == .hibernated }
        var asked = false
        rig.hibernation.workspaceTabs = { _, _ in
            asked = true
            return keys
        }
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        try await rig.until("the hover intent fires") { asked }
        try await Task.sleep(for: BrowserHibernation.hoverDwellDelay * 2)
        #expect(rig.services.cache.phase(of: keys[0]) == .hibernated)
        #expect(rig.hibernation.hoverRestores.pages.isEmpty)
    }

    /// The person's Hibernate Workspace: its pages restore only when shown, never on a hover.
    @Test func aWorkspaceThePersonHibernatedDoesNotWakeOnHover() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false))
        let keys = try await rig.pages(["a", "b"])
        for key in keys { #expect(rig.hibernation.hibernateForWorkspace(key, byPerson: true) == nil) }
        try await rig.until("the workspace's pages hibernate") { keys.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        var asked = false
        rig.hibernation.workspaceTabs = { _, _ in
            asked = true
            return keys
        }
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        try await rig.until("the hover intent fires") { asked }
        try await Task.sleep(for: BrowserHibernation.hoverDwellDelay * 2)
        for key in keys { #expect(rig.services.cache.phase(of: key) == .hibernated, "a page the person hibernated reloaded on hover") }
    }

    /// A newer intent replaces the older: resting on a second row sends the first row's woken pages back,
    /// so at most `HoverWakeBudget.inFlight` hover-restored pages live at once.
    @Test func aNewerWorkspaceIntentSendsTheOlderOnesPagesBack() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false))
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

    /// `browser.keepNeighborTabsAwake` 0: the person asked that no hidden page be kept awake early, so a
    /// hover wakes nothing either.
    @Test func keepNoNeighborTabsAwakeTurnsHoverWakesOff() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var setting = rig.hibernation.setting
        setting.neighborRadius = 0
        rig.hibernation.apply(setting)
        let keys = try await rig.pages(["a", "b", "c"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.hibernation.noteHover(keys[1])
        try await Task.sleep(for: BrowserHibernation.hoverDwellDelay * 4)
        #expect(rig.hibernation.frozen.contains(keys[1]))
    }
}
