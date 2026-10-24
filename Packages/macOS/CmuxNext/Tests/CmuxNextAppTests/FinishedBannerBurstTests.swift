import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// Agent-finished banners that land in one burst collapse per workspace (cx-kz6m0.1, parity with the
/// old app's coalescing queue; RFC #20891 proposal 3). Within the window, a second agent finishing in
/// the same workspace replaces the delivered banner with one that counts them ("3 agents finished",
/// titled with the workspace). Approvals, questions and errors keep their own banners, another workspace keeps its
/// own, and the notification history keeps every row.
@MainActor
struct FinishedBannerBurstTests {
    /// Workspace "api-server" holds surfaces 1, 2 and 3; workspace "web" holds surface 4.
    @MainActor
    final class Harness {
        let store = DaemonStore()
        let service = NotificationCenterService()
        let clock = ManualClock()

        init() {
            _ = NSApplication.shared
            func tab(_ surface: UInt64) -> TabSnapshot {
                TabSnapshot(surface: SurfaceID(rawValue: surface), terminalResourceID: ResourceID(rawValue: "term_\(surface)"))
            }
            let api = WorkspaceSnapshot(id: 1, key: nil, name: "api-server", screens: [
                ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab(1), tab(2), tab(3)])]),
            ])
            let web = WorkspaceSnapshot(id: 2, key: nil, name: "web", screens: [
                ScreenSnapshot(id: 2, layout: .leaf(2), panes: [PaneSnapshot(id: 2, tabs: [tab(4)])]),
            ])
            store.apply(snapshot: DaemonTree(workspaces: [api, web]))
            service.clock = clock
            service.terminalNotificationsEnabled = { true }
        }

        /// Delivers daemon notification `id` from an agent on `surface` as a banner the policy allows.
        func deliver(_ id: UInt64, surface: UInt64, title: String, level: String = "info") throws {
            let wire = #"{"notification":\#(id),"title":"\#(title)","body":"","level":"\#(level)","surface":\#(surface),"source":"agent"}"#
            let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
            store.apply(.notification(notification))
            let located = try #require(service.locate(surface: SurfaceID(rawValue: surface), in: store))
            var decision = NotificationPolicy.Decision()
            decision.desktop = true
            decision.sound = "default"
            service.deliver(notification, source: .agent, located: located, decision: decision, program: nil)
        }

        /// The user reads the tab of `surface` (a banner click, a look at the pane).
        func read(surface: UInt64) throws {
            service.acknowledge(try #require(service.locate(surface: SurfaceID(rawValue: surface), in: store)).tab)
        }

        /// The banners still in Notification Center: posted and not replaced by a digest, oldest first.
        var showing: [String] {
            let replaced = Set(service.finishedBursts.replaced)
            return service.desktop.posted.filter { !replaced.contains($0.id) }.compactMap(\.subtitle)
        }
    }

    @Test func agentsFinishingInOneWorkspaceShareOneBanner() throws {
        let harness = Harness()
        try harness.deliver(5, surface: 1, title: "Claude finished")
        try harness.deliver(6, surface: 2, title: "Claude needs approval", level: "warning")
        try harness.deliver(7, surface: 2, title: "Codex finished")
        try harness.deliver(8, surface: 3, title: "Claude finished")
        try harness.deliver(9, surface: 4, title: "Codex finished")
        #expect(harness.showing == ["Claude needs approval", "3 agents finished", "Codex finished"],
                "the approval and the other workspace keep their own banners")
        #expect(harness.store.notifications.map(\.notification.rawValue) == [5, 6, 7, 8, 9], "the history keeps every row")
        let digest = try #require(harness.service.desktop.posted.first { $0.subtitle == "3 agents finished" })
        #expect(digest.title == "api-server")
        #expect(digest.surface == 3, "clicking it opens the agent that finished last")
        #expect(digest.sound == nil, "the banners it replaces already sounded")
    }

    @Test func oneAgentFinishingTwiceIsNotABurst() throws {
        let harness = Harness()
        try harness.deliver(5, surface: 1, title: "Claude finished")
        try harness.deliver(6, surface: 1, title: "Claude finished")
        #expect(harness.showing == ["Claude finished", "Claude finished"])
    }

    @Test func aFinishAfterTheWindowGetsItsOwnBanner() async throws {
        let harness = Harness()
        try harness.deliver(5, surface: 1, title: "Claude finished")
        try await harness.clock.waitForSleeper()
        harness.clock.advance(by: .seconds(11))
        let workspace = try #require(harness.service.locate(surface: SurfaceID(rawValue: 1), in: harness.store)).workspace.id
        for _ in 0..<1000 where harness.service.finishedBursts.isOpen(workspace: workspace) {
            await Task.yield()
        }
        try harness.deliver(6, surface: 2, title: "Codex finished")
        #expect(harness.showing == ["Claude finished", "Codex finished"], "the window closed: no digest")
    }

    @Test func anAgentTheUserAlreadyReadLeavesTheBurst() throws {
        let harness = Harness()
        try harness.deliver(5, surface: 1, title: "Claude finished")
        try harness.read(surface: 1)
        try harness.deliver(6, surface: 2, title: "Codex finished")
        #expect(harness.service.desktop.posted.compactMap(\.subtitle) == ["Claude finished", "Codex finished"], "the read agent is not counted again")
        #expect(harness.service.desktop.posted.last?.sound == "default", "a banner that replaces nothing still sounds")
    }

    @Test func anAgentFinishingTwiceThenAnotherLeavesOnlyTheDigest() throws {
        let harness = Harness()
        try harness.deliver(5, surface: 1, title: "Claude finished")
        try harness.deliver(6, surface: 1, title: "Claude finished")
        try harness.deliver(7, surface: 2, title: "Codex finished")
        #expect(harness.showing == ["2 agents finished"], "both of the first agent's banners give way")
    }
}
