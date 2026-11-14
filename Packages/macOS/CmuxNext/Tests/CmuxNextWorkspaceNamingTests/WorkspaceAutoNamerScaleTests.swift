import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextWorkspaceNaming
import Testing

/// One workspace's chat title change plans that workspace alone: the work the namer does for it
/// is the same with 64 workspaces shown as with 2 (perf-speed-of-light.md I1, I2; Leo, 2026-11-04:
/// "never ... acceptable ... linear time growth degradation").
@MainActor
struct WorkspaceAutoNamerScaleTests {
    private static let host = "install:auto-name-scale"

    @MainActor
    private final class Fixture {
        let turns = AgentTurnStateStore()
        let workspaces: [WorkspaceModel]
        /// Front-tab reads (`selection`), one per pane of each workspace planned.
        var planned = 0
        var attempts: [String] = []
        let events = AsyncStream<Void>.makeStream()

        init(count: Int) {
            turns.localHost = WorkspaceAutoNamerScaleTests.host
            workspaces = (0..<count).map { index in
                var tab = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, title: "about:blank")
                tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: WorkspaceAutoNamerScaleTests.host,
                                                                                     session: "s\(index)", harness: "claude"))
                let pane = PaneSnapshot(id: 1, tabs: [tab])
                let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
                return WorkspaceModel(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: "auto-name-scale-\(index)"),
                                                        name: "Named \(index)", nameSource: .auto, nameRevision: 1,
                                                        screens: [screen]))
            }
            for index in 0..<count { title("Named \(index)", session: "s\(index)") }
        }

        func title(_ title: String, session: String) {
            let summary: [String: Any] = ["title": title, "titleSource": "generated"]
            turns.apply(session: session, state: nil, lastMessage: nil, muted: false,
                        title: AgentTurnStates.title(summary),
                        generatedTitle: AgentTurnStates.title(summary, includingPrompt: false), detail: nil)
        }

        lazy var namer: WorkspaceAutoNamer = {
            let reader = WorkspaceAutoNameReader(
                enabled: { true }, isNewTabPage: { _ in false },
                livePage: { _ in nil }, incognitoTitle: { _ in nil },
                terminal: { tab in .init(kind: .terminal, userName: nil, title: tab.titleText,
                                         pageTitle: nil, url: nil, cwd: tab.cwd) },
                turns: turns, hold: WorkspaceAutoNameHold())
            return WorkspaceAutoNamer(
                names: reader,
                workspaces: { [weak self] in
                    guard let self else { return [] }
                    return workspaces.map { workspace in
                        .init(machineID: DaemonCommandScope.localMachine, workspace: workspace,
                              supportsNameSource: true, daemonGeneration: nil)
                    }
                },
                selection: { [weak self] _, _ in
                    self?.planned += 1
                    self?.events.continuation.yield()
                    return nil
                },
                rename: { [weak self] _, name, maySend, _ in
                    guard let self, maySend() else { return false }
                    attempts.append(name)
                    events.continuation.yield()
                    return true
                })
        }()
    }

    /// The front-tab reads one title change costs once the namer has planned every workspace.
    private static func plannedForOneTitleChange(workspaces count: Int) async -> Int {
        let fixture = Fixture(count: count)
        let worker = Task { await fixture.namer.run() }
        defer { worker.cancel(); fixture.events.continuation.finish() }
        var iterator = fixture.events.stream.makeAsyncIterator()
        while fixture.planned < count { _ = await iterator.next() }
        fixture.planned = 0
        fixture.title("Renamed 0", session: "s0")
        while fixture.attempts.isEmpty { _ = await iterator.next() }
        #expect(fixture.attempts == ["Renamed 0"])
        let planned = fixture.planned
        worker.cancel()
        await worker.value
        return planned
    }

    @Test(.timeLimit(.minutes(1)))
    func oneChatTitleChangePlansOnlyItsWorkspace() async {
        let small = await Self.plannedForOneTitleChange(workspaces: 2)
        let large = await Self.plannedForOneTitleChange(workspaces: 64)
        print("auto-namer front-tab reads for one title change: W=2 \(small), W=64 \(large)")
        #expect(large <= small, "one title change read \(large) front tabs at 64 workspaces, \(small) at 2")
    }
}
