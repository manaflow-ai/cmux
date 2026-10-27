import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDiff
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNext{AgentLanes,AgentUpdates,AgentPermissions,AgentActivity,AgentQuestion,Diff} sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-341, rule 9): one case per migrated owner
/// class, on a rig whose wakes and frames the test runs.
/// - VisibleObservation: the Chief's pane tools draw nothing while hidden and draw its status in the show turn.
/// - ServiceObservation and MainDeadline: another machine's groups follow a lane change with nothing on screen, but
///   only when the classed refresh deadline fires, never in the change's turn.
/// - Off-main read and classed reply: a language pack file change reaches an open diff tab's listener as one posted
///   task after the read off main.
/// The pull request recheck (MainDeadline) is in SidebarPullRequestCardTests, the update follower's admission
/// (ServiceObservation) in AgentCLIUpdateObservationTests and the diff prefs stream in DiffColorsSettingTests.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentLanesDiffSchedulerSweepTests {
    /// Runs the rig's frames (posted work, observation flushes) until `done` holds, giving the main run loop turns.
    private static func frames(_ rig: MainDeadlineRig, until done: () -> Bool) async throws {
        for _ in 0..<250 where !done() {
            rig.frame()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: VisibleObservation (ChiefPaneTools)

    @Test func hiddenChiefToolsDrawNothingAndDrawTheStatusInTheShowTurn() throws {
        let rig = MainDeadlineRig()
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        let tools = ChiefPaneTools(chief: chief, registry: ActionRegistry(catalog: []), mainWork: rig.work)
        // In no window: the tools' node is under its hidden off-window root. The first status applies at once.
        #expect(tools.indicator.state == .idle)

        chief.status = ChiefSidebar.Status(activity: .waiting, badge: 1)
        rig.frame()
        #expect(tools.indicator.state == .idle, "hidden pane tools drew the Chief's status")
        #expect(!tools.hasSubagents)

        try tools.visibilityNode.attach(to: VisibilityNode(root: "test.window", own: .visible))
        #expect(tools.indicator.state == .waiting, "the pane tools did not draw the status in the show turn")
    }

    // MARK: ServiceObservation and MainDeadline (RemoteMachinesSidebar)

    @Test func aLaneChangeRebuildsTheMachinesOnlyWhenTheClassedRefreshFires() async throws {
        let rig = MainDeadlineRig()
        let lanes = AgentLaneStore()
        let sidebar = RemoteMachinesSidebar(lanes: lanes)
        sidebar.bind(host: .init(peers: { nil }, older: { _, _ in nil }, displayName: { _ in nil }, open: { _ in }),
                     deadlines: rig.deadlines)
        defer { sidebar.stop() }
        // The bind's own refresh, then the peer read's answer (nil: no peer list), so nothing is pending.
        rig.fireAndRun()
        for _ in 0..<5 { rig.frame() }
        #expect(sidebar.machines.isEmpty)

        lanes.lanes["vm/a"] = AgentActivityLane(id: "vm/a", name: "vm/a", title: "Build", peer: "vm", parent: nil,
                                                state: .working, since: Date(), error: nil)
        for _ in 0..<5 { rig.frame() }
        #expect(sidebar.machines.isEmpty, "the groups rebuilt before the refresh deadline")
        #expect(rig.hasArmedWake, "the lane change armed no refresh, though no sidebar is on screen")

        rig.fireAndRun()
        #expect(sidebar.machines.map(\.peer) == ["vm"], "the refresh did not rebuild the groups")
        #expect(sidebar.machines.first?.chats.map(\.id) == ["vm/a"])
    }

    // MARK: Off-main read, classed reply (DiffLanguageFeed)

    @Test func aLanguageFileChangeReachesTheListenerAsOnePostedTask() async throws {
        let rig = MainDeadlineRig()
        let base = FileManager.default.temporaryDirectory.appending(path: "diff-languages-\(UUID().uuidString)")
        let folder = DiffLanguagePack.directory(configFile: base.appending(path: "cmux.json"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let feed = DiffLanguageFeed(directory: folder, mainWork: rig.work)
        var packs: [JSONValue] = []
        let stop = feed.listen { packs.append($0) }
        defer { stop() }
        // The first read only fills the cache, then the folder is watched.
        try await Self.frames(rig) { feed.watcherCount > 0 }
        #expect(feed.watcherCount > 0, "the first read did not land on main")
        #expect(packs.isEmpty, "the first read was pushed as a change")

        try Data(#"{"name":"toy"}"#.utf8).write(to: folder.appending(path: "toy.json"))
        try await Self.frames(rig) { !packs.isEmpty }
        let files = packs.last?["files"]?.arrayValue ?? []
        #expect(files.count == 1, "the new language file did not reach the listener")
        #expect(files.first?["path"]?.stringValue == "toy.json")
    }
}
