import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextDesign
@testable import CmuxNextDiff
@testable import CmuxNextHome
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNext{AgentLanes,AgentUpdates,AgentPermissions,AgentActivity,AgentQuestion,Diff} sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): one case per migrated owner
/// class, on a rig whose wakes and frames the test runs.
/// - VisibleObservation: the Chief's pane tools draw nothing while hidden and draw its status in the show turn.
/// - ServiceObservation (side effect while hidden): the tab row setting turned back on lays the dock out again while
///   the Chief's tools are hidden.
/// - ServiceObservation and MainDeadline: another machine's groups follow a lane change with nothing on screen, but
///   only when the classed refresh deadline fires, never in the change's turn.
/// - Person: the Older page a click asked for lands as userBlocking on the next turn, ahead of visible work that
///   waits for its frame.
/// - Automation: a CLI archive's refusal does not run under the person's pending input; it runs once the input drains.
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

    // MARK: ServiceObservation, side effect while hidden (ChiefPaneTools.rowSetting)

    @Test func theTabRowSettingTurnedBackOnLaysTheDockOutWhileTheToolsAreHidden() throws {
        let key = ChromeTunables.tabRowTools.descriptor.key
        // Debug Settings overrides apply once the store is active; no file, so nothing is written.
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([ChromeTunables.tabRowTools.descriptor])
        try #require(TunableStore.shared.set(key, .bool(false)) == .bool(false), "the toggle takes the override")
        defer { TunableStore.shared.set(key, nil) }
        let rig = MainDeadlineRig()
        let tools = ChiefPaneTools(chief: ChiefSidebar(lanes: AgentLaneStore()), registry: ActionRegistry(catalog: []), mainWork: rig.work)
        let dock = HomeDockTabRowToolsTests.Dock(mode: .messages)
        dock.rowTools = [.messages: tools]
        dock.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        dock.setTabRow(height: 28, trailingInset: 40)
        dock.layoutSubtreeIfNeeded()
        #expect(tools.superview === dock)
        #expect(tools.isHidden, "the dock showed the tools with the setting off")
        #expect(!dock.needsLayout)

        TunableStore.shared.set(key, .bool(true))
        for _ in 0..<3 { rig.frame() }
        #expect(dock.needsLayout, "the setting came back on while the tools were hidden and the dock was not laid out again")
        dock.layoutSubtreeIfNeeded()
        #expect(!tools.isHidden, "the Chief's tools did not come back with the setting")
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

    // MARK: Person (RemoteMachinesSidebar.older)

    @Test func aClickedOlderPageLandsAsUserBlockingAheadOfVisibleWork() async throws {
        let rig = MainDeadlineRig()
        let sidebar = RemoteMachinesSidebar(lanes: AgentLaneStore())
        let page = AcpmuxSessionPage.Page(chats: [.init(id: "old-1", title: "Closed chat", harness: nil)], next: nil)
        sidebar.bind(host: .init(peers: { nil }, older: { _, _ in page }, displayName: { _ in nil }, open: { _ in }),
                     deadlines: rig.deadlines)
        defer { sidebar.stop() }
        // The bind's own refresh and its peer read, so nothing else is pending.
        rig.fireAndRun()
        for _ in 0..<5 { rig.frame() }
        var visibleRan = false
        rig.work.post(.visible, owner: "test.visible") { visibleRan = true }

        #expect(sidebar.activate(LayoutItemID(LayoutItemID.transientPrefix + "remote:older:vm")))
        // No frame: a userBlocking reply runs on the next run loop turn, visible work waits for its frame.
        for _ in 0..<250 where sidebar.older["vm"]?.read != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sidebar.older["vm"]?.chats.map(\.id) == ["old-1"], "the person's Older page waited for a frame")
        #expect(!visibleRan, "the visible work ran without its frame")

        rig.frame()
        #expect(visibleRan, "the visible work did not run on its frame")
    }

    // MARK: Automation (AgentPriorityChats.archive)

    @Test func aCLIArchiveRefusalYieldsToThePersonsPendingInput() async throws {
        let input = AgentLanesSweepInput()
        let rig = MainDeadlineRig(input: input)
        let store = AgentLaneStore()
        store.socketPath = "/tmp/acpmux-sweep.sock"
        store.lanes["c"] = AgentActivityLane(id: "c", name: "c", title: "Build", peer: nil, parent: nil, state: .idle,
                                             since: Date(), error: nil)
        let marks = AgentPriorityMarks(defaults: nil)
        let chats = AgentPriorityChats(marks: marks, stores: [store], checksFailing: { _ in false },
                                       archive: { _, _ in throw AgentLanesSweepRefusal() })
        let invocation = ActionInvocation(origin: .cli)
        #expect(invocation.completionClass == .automation)

        input.pending = true
        #expect(chats.archive("c", on: rig.work, as: invocation.completionClass))
        #expect(marks.state.archived.contains("c"), "the archive did not hide the chat at once")
        // The refusal reaches main on a run loop turn; under pending input its automation task stays queued.
        for _ in 0..<250 where rig.work.postedCount(.automation) == 0 && marks.state.archived.contains("c") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.work.postedCount(.automation) == 1, "the refusal was not one queued automation task")
        #expect(marks.state.archived.contains("c"), "the CLI's refusal ran ahead of the person's pending input")

        input.pending = false
        rig.frame()
        #expect(!marks.state.archived.contains("c"), "the refusal did not show the chat again once the input drained")
        #expect(rig.work.postedCount(.automation) == 0)
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

/// A person's input the test holds pending.
@MainActor
private final class AgentLanesSweepInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// acpmux refused the archive.
private struct AgentLanesSweepRefusal: Error {}
