import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// Records the target of each run that reached it and lets it run; as the App would, it finds
/// the targets in `unavailable` not available before any run (`firstUnavailable`).
private final class TargetRecordingExecutor: ControlActionExecutor {
    let targets = Mutex<[String]>([])
    let unavailable: Set<String>

    init(unavailable: Set<String> = []) { self.unavailable = unavailable }

    static func name(_ request: ControlActionRequest) -> String { request.target.map { "\($0.kind):\($0.id)" } ?? "none" }

    @MainActor func firstUnavailable(_ requests: [ControlActionRequest]) -> Int? {
        requests.firstIndex { unavailable.contains(Self.name($0)) }
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        targets.withLock { $0.append(Self.name(request)) }
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

    fileprivate static func router(_ executor: TargetRecordingExecutor, topology: ControlTopology?) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { snapshot in
            snapshot.catalog = Self.catalog()
            if let topology { snapshot.topology = topology }
        }
        return router
    }

    func run(_ action: String, _ target: String, topology: ControlTopology?) async -> (Result<JSONValue, ControlError>, [String]) {
        let executor = TargetRecordingExecutor()
        let router = Self.router(executor, topology: topology)
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

    /// The router no longer refuses a pane target that shows no chat before a batch runs, so the
    /// App's up-front check (`firstUnavailable`) does: an atomic batch whose second op the App
    /// would refuse applies nothing, not its first op.
    @Test func aBatchWithAnOpTheAppWouldRefuseAppliesNothing() async {
        let executor = TargetRecordingExecutor(unavailable: ["pane:pane-term"])
        let router = Self.router(executor, topology: nil)
        let op: (String) -> JSONValue = { ["action": "agentPane.setModel", "target": .string($0), "args": ["model": "opus"]] }
        let result = await router.handle(ControlRequest(id: "1", method: "action.batch", params: [
            "ops": [op("pane:pane-chat"), op("pane:pane-term")],
        ]))
        guard case .failure(let error) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.data?["op"] == 1)
        #expect(error.data?["not_run"] == true)
        #expect(executor.seen.isEmpty, "op 0 applied before op 1 was refused")
    }

    /// `atomic: false` with transactions of one op: the refused op 2 is named and nothing ran.
    @Test func aNonAtomicBatchIsCheckedWholeBeforeItsFirstTransaction() async {
        let executor = TargetRecordingExecutor(unavailable: ["pane:pane-term"])
        var configuration = ControlRouter.Configuration.loadTolerant
        configuration.batchOpLimit = 1
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: configuration)
        router.snapshots.publish { $0.catalog = Self.catalog() }
        let op: (String) -> JSONValue = { ["action": "agentPane.setModel", "target": .string($0), "args": ["model": "opus"]] }
        let result = await router.handle(ControlRequest(id: "1", method: "action.batch", params: [
            "ops": [op("pane:pane-chat"), op("tab:tab-chat"), op("pane:pane-term")], "atomic": false,
        ]))
        guard case .failure(let error) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.data?["op"] == 2)
        #expect(error.data?["not_run"] == true)
        #expect(executor.seen.isEmpty, "a transaction applied before the refused op")
    }

    @Test func onlyPaneAndTabTargetsDeferTheirFactsToTheRegistry() {
        #expect(ControlCatalog.deferredToRegistry(byTargetKind: .pane) == [.agentPaneFocused, .canvasLayout])
        #expect(ControlCatalog.deferredToRegistry(byTargetKind: .tab) == [.agentPaneFocused, .canvasLayout])
        for kind: ActionTargetKind? in [nil, .workspace, .window, .machine, .agentChat] {
            #expect(ControlCatalog.deferredToRegistry(byTargetKind: kind) == [], "\(String(describing: kind))")
        }
    }
}
