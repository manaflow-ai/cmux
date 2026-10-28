import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// Records the target of each run that reached it and lets it run.
private final class TargetRecordingExecutor: ControlActionExecutor {
    let targets = Mutex<[String]>([])

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        targets.withLock { $0.append(request.target.map { "\($0.kind):\($0.id)" } ?? "none") }
        return .ran
    }

    var seen: [String] { targets.withLock { $0 } }
}

/// `cmux agent set-model --target pane:<id>` (and `tab:<id>`) used to be refused
/// "not available in the current context" when no agent chat had the keyboard.
/// `action.run` checked the action's `agentPaneFocused` requirement against the
/// snapshot's focus and the target's kind alone, before the registry could read
/// whether the pane or tab shows a chat (`ActionRegistry.targetContext`). So only
/// `agent-chat:<session>` reached the handler. The router now leaves the facts a
/// pane or tab target may bring to that live check (`ControlCatalog.deferredToRegistry`)
/// and does not decide them from a snapshot that can be missing or stale. The
/// App-level run through the real registry is `AgentChatTargetAppTests`.
@Suite(.timeLimit(.minutes(1))) struct AgentChatTargetAvailabilityTests {
    static func catalog() -> ControlCatalog {
        let model = ControlArgumentInfo(name: "model", title: "Model", kind: .string, isRequired: false)
        let setModel = ControlActionInfo(
            id: "agentPane.setModel", title: "Set Agent Chat Model", category: "agents", categoryTitle: "Agents",
            cliName: "agent set-model", symbol: "cpu", keywords: [], shortcut: nil, shortcutConfig: nil, arguments: [model],
            targets: ["pane", "tab", "agent-chat"], requiresMask: ActionContext.agentPaneFocused.rawValue,
            requires: ["agentPaneFocused"], isBound: true, isDebugOnly: false, mainMenu: nil)
        // A fact no pane can bring: a pane target still cannot stand in for it.
        let pause = ControlActionInfo(
            id: "cloudPauseMachine", title: "Pause Machine", category: "cloud", categoryTitle: "Cloud",
            cliName: "cloud pause-machine", symbol: "pause.circle", keywords: [], shortcut: nil, shortcutConfig: nil, arguments: [],
            targets: ["pane", "machine"], requiresMask: ActionContext.cloudWorkspace.rawValue,
            requires: ["cloudWorkspace"], isBound: true, isDebugOnly: false, mainMenu: nil)
        return ControlCatalog(actions: [setModel, pause], contextMask: 0, aliases: [:],
                              targetKinds: ActionTargetKind.allCases.map(\.rawValue), debugActionsAvailable: false)
    }

    /// A topology that lists pane-chat and its tab tab-chat but has not caught up
    /// with the chat in it (no `agentSessionID`).
    static func staleTopology() -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = "connected"
        let tab = ControlTabInfo(id: "tab-chat", surface: "21", kind: "terminal", title: "~")
        let pane = ControlPaneInfo(id: "pane-chat", handle: "5", selectedTabID: "tab-chat", tabs: [tab])
        topology.workspaces = [ControlWorkspaceInfo(id: "ws-1", handle: "1", name: "Main",
                                                    screens: [ControlScreenInfo(id: "screen-1", handle: "2", panes: [pane])])]
        return topology
    }

    func run(_ action: String, _ target: String, topology: ControlTopology?) async -> (Result<JSONValue, ControlError>, [String]) {
        let executor = TargetRecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { snapshot in
            snapshot.catalog = Self.catalog()
            if let topology { snapshot.topology = topology }
        }
        var params: [String: JSONValue] = ["action": .string(action), "target": .string(target)]
        if action == "agentPane.setModel" { params["args"] = ["model": "opus"] }
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: params))
        return (result, executor.seen)
    }

    @Test(arguments: ["pane:pane-chat", "tab:tab-chat", "agent-chat:sess-1"])
    func aChatTargetReachesTheAppWithNoSnapshotYet(_ target: String) async throws {
        let (result, seen) = await run("agentPane.setModel", target, topology: nil)
        _ = try result.get()
        #expect(seen == [target], "the router refused \(target) before the App's live check")
    }

    @Test(arguments: ["pane:pane-chat", "tab:tab-chat"])
    func aChatTargetReachesTheAppWhenTheSnapshotHasNotSeenItsChat(_ target: String) async throws {
        let (result, seen) = await run("agentPane.setModel", target, topology: Self.staleTopology())
        _ = try result.get()
        #expect(seen == [target], "a stale snapshot refused \(target) before the App's live check")
    }

    @Test func aPaneTargetStillCannotStandInForAFactOnlyFocusBrings() async {
        let (result, seen) = await run("cloudPauseMachine", "pane:pane-chat", topology: nil)
        guard case .failure(let error) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.data?["not_run"] == true)
        #expect(seen.isEmpty)
    }

    @Test func onlyPaneAndTabTargetsDeferTheirFactsToTheRegistry() {
        #expect(ControlCatalog.deferredToRegistry(byTargetKind: .pane) == [.agentPaneFocused, .canvasLayout])
        #expect(ControlCatalog.deferredToRegistry(byTargetKind: .tab) == [.agentPaneFocused, .canvasLayout])
        for kind: ActionTargetKind? in [nil, .workspace, .window, .machine, .agentChat] {
            #expect(ControlCatalog.deferredToRegistry(byTargetKind: kind) == [], "\(String(describing: kind))")
        }
    }
}
