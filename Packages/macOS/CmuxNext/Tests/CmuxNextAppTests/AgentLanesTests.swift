import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-v9k2f: the lanes view makes an agent that went idle or stuck obvious. acpmux decides each
/// session's lane (the summary's `lane`); the app's watch feed mirrors it and, while Labs preview
/// features are on, the sidebar's Lanes item counts the sessions a person should look at: waiting
/// on them, failed (with why, e.g. "Credit balance too low") or lost. On 2026-10-13 about 25
/// lanes sat idle for hours unnoticed, some dead on out-of-credit errors.
@MainActor
@Suite(.serialized)
struct AgentLanesTests {
    /// One session summary as acpmux sends it, with its lane.
    static func summary(_ id: String, _ state: String, since: Double = 1_760_000_000_000, error: String? = nil,
                        parent: String? = nil, peer: String? = nil, workspaceID: String? = nil) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": id, "name": id, "status": "idle",
                                      "lane": ["state": state, "since": since, "error": error as Any]]
        if let parent { summary["tags"] = [AgentActivityLane.parentTag: parent] }
        if let peer { summary["peer"] = peer; summary["name"] = "\(peer)/\(id)" }
        if let workspaceID { summary["workspaceId"] = workspaceID }
        return summary
    }

    /// One session in each lane state, on this Mac and an acpmux peer, under a coordinator.
    static let sessions: [[String: Any]] = [
        summary("chief", "working"),
        summary("op-busy", "working", parent: "chief"),
        summary("op-idle", "idle", parent: "chief"),
        summary("op-broke", "failed", error: "Credit balance too low", parent: "chief"),
        summary("op-asks", "input", parent: "chief"),
        summary("op-gone", "lost", peer: "mini"),
    ]

    @Test func everySessionShowsItsLaneAndTheSidebarCountsTheOnesThatNeedAPerson() async throws {
        // The fleet toggle counts the coordinator's children and the peer's lane too.
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TunableCatalog.all)
        TunableStore.shared.set(AgentActivityTunables.lanesShowFleet.key, .bool(true))
        defer { TunableStore.shared.set(AgentActivityTunables.lanesShowFleet.key, nil) }
        let acpmux = try StandInAcpmux(sessions: Self.sessions)
        let lanes = AgentLaneStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: AgentTurnStateStore(), lanes: lanes)
        feed.start(localHost: "install:lanes")
        try await until { lanes.lanes.count == Self.sessions.count }

        #expect(lanes.lanes["op-broke"]?.state == .failed)
        #expect(lanes.lanes["op-broke"]?.error == "Credit balance too low")
        #expect(lanes.lanes["op-broke"]?.parent == "chief")
        #expect(lanes.lanes["op-asks"]?.state == .input)
        #expect(lanes.lanes["op-idle"]?.state == .idle)
        #expect(lanes.lanes["op-idle"]?.since == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(lanes.lanes["op-gone"]?.peer == "mini")
        #expect(SidebarTransientItem.lanes(lanes)?.info.badge == 3, "failed, waiting and lost need a person")

        // The idle lane dies on its next turn: the count follows the push, no poll.
        acpmux.push(Self.summary("op-idle", "failed", error: "Credit balance too low", parent: "chief"))
        try await until { lanes.lanes["op-idle"]?.state == .failed }
        #expect(SidebarTransientItem.lanes(lanes)?.info.badge == 4)

        // A person answered the permission; the lane works again.
        acpmux.push(Self.summary("op-asks", "working", parent: "chief"))
        try await until { lanes.lanes["op-asks"]?.state == .working }
        #expect(SidebarTransientItem.lanes(lanes)?.info.badge == 3)

        // A closed session has no lane and leaves the view.
        acpmux.push(["sessionId": "op-busy", "name": "op-busy", "status": "closed", "lane": NSNull()])
        try await until { lanes.lanes["op-busy"] == nil }
        #expect(lanes.lanes["op-busy"] == nil)
        withExtendedLifetime((acpmux, feed)) {}
    }

    @Test func aLanePreservesTheExistingSessionWorkspaceBinding() {
        let summary = Self.summary("codex-1", "working", workspaceID: "workspace-7")
        let lane = AgentActivityLane.of(summary: summary)
        #expect(lane?.workspaceID == "workspace-7")
    }

    /// hq#2509: a lane row says which harness owns it and what it is doing now. acpmux masks
    /// secrets in `lane.step` before the summary leaves it; the raw prompt beside it still holds
    /// the token, so the app reads only `lane.step` and never falls back to the prompt.
    @Test func aLaneShowsTheDaemonsMaskedStepNeverTheRawPrompt() {
        let token = "gh" + "p_" + "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"
        var summary = Self.summary("op-busy", "working")
        summary["harness"] = "codex"
        summary["turn"] = ["prompt": "push with \(token)", "startedAt": 1_760_000_500_000.0]
        summary["lastMessage"] = ["role": "agent", "text": token]
        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull(), "step": "push with [github token]"]
        let lane = AgentActivityLane.of(summary: summary)
        #expect(lane?.harness == "codex")
        #expect(lane?.step == "push with [github token]")

        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull()]
        #expect(AgentActivityLane.of(summary: summary)?.step == nil, "an acpmux from before lane.step shows no step")
    }

    /// hq#2509: a lane's title is acpmux's masked `lane.title`, never the summary's raw title or
    /// latest prompt; an acpmux from before it shows the session's name.
    @Test func aLanesTitleIsTheDaemonsMaskedTitle() {
        let token = "gh" + "p_" + "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"
        var summary = Self.summary("op-busy", "working")
        summary["title"] = "push \(token)"
        summary["lastPrompt"] = "push \(token)"
        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull(), "title": "push [github token]"]
        #expect(AgentActivityLane.of(summary: summary)?.title == "push [github token]")
        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull()]
        #expect(AgentActivityLane.of(summary: summary)?.title == "op-busy")
    }

    /// Leo 2026-10-20: "I'm not sure which ones are actually running... Isn't there an expanded
    /// view of things?" The lanes view is that view, so the sidebar's Lanes item shows by default,
    /// not only while Labs preview features are on, and stays with Labs off.
    @Test func theLanesItemShowsWithoutLabsPreviewFeatures() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-lanes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let lanes = AgentLaneStore()
        lanes.lanes = ["op-broke": AgentActivityLane(id: "op-broke", name: "op-broke", title: "op-broke", peer: nil, parent: nil,
                                                     state: .failed, since: nil, error: "Credit balance too low", workspaceID: nil)]
        let model = SidebarModel()
        let feed = SidebarWhatsNewItemFeed.start(model: model, settings: settings, lanes: lanes)
        defer { feed.cancel() }
        let lanesItem = { model.transientTopItems.first { $0.item.id == SidebarTransientItem.lanesID } }

        try await until { lanesItem() != nil }
        #expect(lanesItem()?.info.badge == 1, "on by default: the failed session counts")

        try Data(#"{"labs": {"previewFeatures": false}}"#.utf8).write(to: url)
        await settings.reload()
        try await Task.sleep(for: .milliseconds(200))
        #expect(lanesItem() != nil, "Labs off keeps the Lanes item")

        lanes.lanes = [:]
        try await until { lanesItem() == nil }
        #expect(lanesItem() == nil, "no lane: no Lanes item")
    }

    /// Leo 2026-10-15: the Lanes item counts his own sessions on this Mac, not every acpmux peer's
    /// fleet lane or a coordinator's child session, and hides when he has none. The fleet shows
    /// behind the Debug Settings toggle `agentActivity.lanesShowFleet`, off by default.
    @Test func theLanesItemCountsOnlyThisMacsOwnSessionsUnlessTheFleetToggleIsOn() {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TunableCatalog.all)
        let key = "agentActivity.lanesShowFleet"
        defer { TunableStore.shared.set(key, nil) }
        func lane(_ id: String, peer: String? = nil, parent: String? = nil) -> AgentActivityLane {
            AgentActivityLane(id: id, name: id, title: id, peer: peer, parent: parent, state: .failed, since: nil, error: nil)
        }
        let store = AgentLaneStore()
        store.lanes = ["mine": lane("mine"), "op-peer": lane("op-peer", peer: "mini"), "op-child": lane("op-child", parent: "chief")]
        let item = { () -> SidebarTransientItem? in SidebarTransientItem.lanes(store) }

        #expect(item() != nil, "an own session shows the item")
        #expect(item()?.info.badge == 1, "off by default: only the own session counts")

        store.lanes["mine"] = nil
        #expect(item() == nil, "only fleet and child lanes: no Lanes item")

        store.lanes["mine"] = lane("mine")
        #expect(TunableStore.shared.set(key, .bool(true)) == .bool(true), "the fleet toggle exists")
        #expect(item()?.info.badge == 3, "the fleet toggle counts peer and child lanes too")
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
