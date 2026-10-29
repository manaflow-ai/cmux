import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Testing
@testable import CmuxNextWorkspaceNaming

/// p06-scheduler-339 (rule 9, side effects while hidden): the auto-namer's follow is a ServiceObservation with no
/// visibility node, so a chat's title renames its default-named workspace while no window shows it, in one visible
/// task after the change that titled the chat.
@MainActor struct WorkspaceAutoNamerFollowTests {
    final class Renames { var names: [String] = [] }

    /// A main-thread scheduler with no display link whose posted turns the test runs (`run`).
    final class Turns {
        private final class Queue { var turns: [@MainActor () -> Void] = [] }
        private let queue: Queue
        let work: MainWorkScheduler

        init() {
            let queue = Queue()
            self.queue = queue
            work = MainWorkScheduler.testing(performTurn: { queue.turns.append($0) }) { _ in nil }
        }

        func run() {
            while !queue.turns.isEmpty { queue.turns.removeFirst()() }
        }
    }

    /// Workspace "workspace-1" (a default name) whose one pane shows chat `s1`.
    static func chatWorkspace() -> WorkspaceModel {
        var chat = TabSnapshot(surface: 1, kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: TornOffWorkspaceNameTests.host, session: "s1", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        return WorkspaceModel(WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "w1"), name: "workspace-1", screens: [screen]))
    }

    @Test func aChatTitleRenamesItsWorkspaceWithNoWindowInOneVisibleTask() {
        let turns = TornOffWorkspaceNameTests.turns([:])
        let workspace = Self.chatWorkspace()
        let target = WorkspaceAutoNamer.Target(machineID: DaemonCommandScope.localMachine, workspace: workspace, supportsNameSource: true,
                                               daemonGeneration: nil, nameSource: .auto, nameRevision: 0)
        let renames = Renames(), scheduler = Turns()
        let namer = WorkspaceAutoNamer(names: TornOffWorkspaceNameTests.reader(turns), workspaces: { [target] },
                                       selection: { _, _ in nil }, rename: { _, name, maySend, _ in
                                           guard maySend() else { return false }
                                           renames.names.append(name)
                                           return true
                                       })
        let follow = namer.follow(on: scheduler.work)
        defer { withExtendedLifetime(follow) {} }
        #expect(renames.names.isEmpty, "an untitled chat renamed its workspace")

        turns.apply(session: "s1", state: nil, lastMessage: nil, muted: false, title: "Fix the sidebar drag",
                    generatedTitle: "Fix the sidebar drag", detail: nil)
        #expect(renames.names.isEmpty, "the rename went out inside the title's change")
        #expect(scheduler.work.postedCount(.visible) == 1, "the title posted no visible task")
        scheduler.run()
        #expect(renames.names == ["Fix the sidebar drag"], "the follow sent no rename while no window showed the workspace")
    }
}
