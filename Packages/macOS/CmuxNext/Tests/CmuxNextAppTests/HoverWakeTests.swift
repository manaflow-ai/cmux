import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
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

        for key in far {
            rig.hibernation.noteHover(key)
            try await Task.sleep(for: .milliseconds(8))
        }
        rig.hibernation.noteHover(nil)
        try await Task.sleep(for: .milliseconds(400))

        for key in far {
            #expect(rig.hibernation.frozen.contains(key), "a tab the pointer only crossed woke")
            #expect(rig.hibernation.exemptions[key] != .neighbor, "a tab the pointer only crossed is kept awake")
        }
        #expect(rig.hibernation.prewarmedCount == prewarmed)
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
        #expect(rig.hibernation.hoverRestored == Set(keys.prefix(2)))

        let later = ContinuousClock.now + .seconds(BrowserHibernation.hoverGrace + 1)
        rig.hibernation.now = { later }
        rig.hibernation.replan()
        try await rig.until("the woken pages hibernate again") { keys.prefix(2).allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }
        #expect(rig.hibernation.hoverRestored.isEmpty)
    }

    /// A page the person hibernated (Hibernate Tab) does not restore on a workspace row's hover.
    @Test func aWorkspaceHoverLeavesThePersonsHibernatedPageAlone() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil))
        let keys = try await rig.pages(["a"])
        #expect(rig.hibernation.hibernateNow(keys[0]) == nil)
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: keys[0]) == .hibernated }
        rig.hibernation.workspaceTabs = { _, _ in keys }
        rig.hibernation.noteWorkspaceHover("w", window: "win")
        try await Task.sleep(for: BrowserHibernation.hoverDwellDelay * 4)
        #expect(rig.services.cache.phase(of: keys[0]) == .hibernated)
        #expect(rig.hibernation.hoverRestored.isEmpty)
    }
}
