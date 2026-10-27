import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import Testing

/// Automation latency (p09-observability task 115): the caller's flow and source reach the action's commit
/// whichever method led to the run (`tab.focus`, `file.open` run `action.run` on the caller's behalf), and a line
/// names its source at the top level, beside its flow.
extension ControlSocketServerTests {
    /// A router whose snapshot has the sample topology (tab `tab-1` in pane `pane-1`) and the `tab.focus` and
    /// `file.open` actions.
    static func flowRouter() -> (ControlRouter, RecordingExecutor) {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        var snapshot = ControlSnapshot.sample()
        let path = ControlArgumentInfo(name: "path", title: "Path", kind: .string, isRequired: true)
        let place = ControlArgumentInfo(name: "where", title: "Where", kind: .string, isRequired: false)
        let fileOpen = ControlActionInfo(id: "file.open", title: "Open File", category: "file", categoryTitle: "File", cliName: "file open",
                                         symbol: "doc", keywords: [], shortcut: nil, shortcutConfig: nil, arguments: [path, place],
                                         targets: ["pane"], requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil)
        snapshot.catalog = ControlCatalog(actions: [BrowserPageTabsTests.action("tab.focus"), fileOpen], targetKinds: ["tab", "pane"],
                                          debugActionsAvailable: false)
        router.snapshots.publish { $0 = snapshot }
        return (router, executor)
    }

    @Test func tabFocusAndFileOpenCarryTheCallersFlowToTheAction() async throws {
        let (router, executor) = Self.flowRouter()
        _ = await router.response(forLine: #"{"id":1,"method":"tab.focus","params":{"tab":"tab-1","wait":false},"flow":77,"source":"cli"}"#,
                                  connection: ControlConnectionID(rawValue: 5))
        let focused = try #require(executor.last)
        #expect(focused.actionID == "tab.focus")
        #expect(focused.flow == 77, "tab.focus forwards the caller's flow to its action.run")

        _ = await router.response(forLine: #"{"id":2,"method":"file.open","params":{"path":"/tmp/notes.md"},"flow":88,"source":"cli"}"#,
                                  connection: ControlConnectionID(rawValue: 5))
        let opened = try #require(executor.last)
        #expect(opened.actionID == "file.open")
        #expect(opened.flow == 88, "file.open forwards the caller's flow to each path's action.run")
    }

    @Test func aForwardedScopedRequestGetsItsQueuedAndDispatchedMarksAndItsSource() async throws {
        let ring = TraceRing(records: 1024, role: .app)
        let (runtime, store) = Self.recordingRuntime(ring)
        let (router, executor) = Self.flowRouter()
        let connection = ControlConnectionID(rawValue: 6)
        let scope = ControlRequestScope(connection: connection, runtime: runtime)
        _ = await router.response(forLine: #"{"id":1,"method":"tab.focus","params":{"tab":"tab-1","wait":false},"flow":99,"source":"mcp"}"#,
                                  connection: connection, scope: scope)
        scope.replied()
        #expect(executor.last?.flow == 99)

        let image = try #require(ring.decodedImage())
        let marks = Self.scopeRecords(image, .instant).map { UInt8(truncatingIfNeeded: $0.arg0 >> 56 & 0x7F) }
        #expect(marks == [ControlRequestScope.Mark.parsed, .queued, .dispatched].map(\.rawValue))
        #expect(Self.scopeRecords(image, .flowOut).map(\.arg1) == [99])
        let end = try #require(Self.scopeRecords(image, .asyncEnd).first)
        #expect(end.arg0 >> 32 & 0xFF == UInt64(ControlRequestScope.Source.mcp.rawValue), "the line's own source")
        #expect(store.totals().histograms.first { $0.name == "automation.main_queue_us" }?.count == 1)
    }

    @Test func aForwardedRequestKeepsTheCallersIDFlowSourceAndScopeButNotItsApp() {
        let scope = ControlRequestScope(connection: ControlConnectionID(rawValue: 4), runtime: TraceRuntime(role: .app))
        var request = ControlRequest(id: JSONValue(9), method: "tab.focus", params: ["tab": "tab-1"], callerApp: "cmux/agents", flow: 77,
                                     source: .agent)
        request.scope = scope
        let forwarded = request.forwarded(method: "action.run", params: ["action": "tab.focus"])
        #expect(forwarded.id == JSONValue(9))
        #expect(forwarded.method == "action.run")
        #expect(forwarded.params == ["action": "tab.focus"])
        #expect(forwarded.flow == 77)
        #expect(forwarded.source == .agent)
        #expect(forwarded.scope === scope)
        #expect(forwarded.callerApp == nil, "a derived request keeps the principal it had before")
    }

    @Test func theLineNamesItsSourceBesideItsFlow() throws {
        let socket = ControlConnectionID(rawValue: 3)
        let named: [(String, ControlRequestScope.Source)] = [("cli", .cli), ("mcp", .mcp), ("agent", .agent)]
        for (text, source) in named {
            let request = try ControlWire.decode(#"{"id":1,"method":"feed.list","params":{},"flow":5,"source":""# + text + #""}"#).get()
            #expect(request.source == source, "\(text)")
            #expect(request.params == [:], "the source is a top-level field: params stay as sent")
            #expect(ControlRequestScope.Source(request, connection: socket) == source, "\(text)")
        }
        // A line never claims the app, and any other shape is ignored, never refused.
        for shape in [#""app""#, #""person""#, "1", "null", "true"] {
            let line = #"{"id":1,"method":"feed.list","source":"# + shape + "}"
            #expect(try ControlWire.decode(line).get().source == nil, "source \(shape)")
        }
        // The named source wins over the older params reading; in process is always the app.
        let cliOverParams = ControlRequest(method: "browser.page.eval", params: ["origin": "mcp"], source: .cli)
        #expect(ControlRequestScope.Source(cliOverParams, connection: socket) == .cli)
        #expect(ControlRequestScope.Source(ControlRequest(method: "feed.list", source: .mcp), connection: .inProcess) == .app)
    }

    /// The bridge hands the request's flow to the run, and the run's `action.commit` ends it with a flow-in.
    @MainActor
    @Test func aBridgedRunEndsTheCallersFlowAtItsCommit() throws {
        @MainActor final class Recorder {
            var flows: [UInt64] = []
        }
        let ring = TraceRing(records: 256, role: .app)
        let runtime = TraceRuntime(role: .app)
        _ = runtime.attach(ring)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.action.traceBit))
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.flow", title: "Flow", category: .other)],
                                      runTiming: SignpostActionRunTiming(monitor: ActionBudgetMonitor(), trace: runtime))
        let recorder = Recorder()
        registry.bind("test.flow", invoke: { recorder.flows.append($0.flow) })
        let bridge = RegistryControlBridge(registry: registry)
        var request = ControlActionRequest(actionID: "test.flow")
        request.flow = (4_321 << 32) | 7
        #expect(bridge.performAction(request) == .ran)
        #expect(recorder.flows == [request.flow], "ActionInvocation.flow is the request's")

        let image = try #require(ring.decodedImage())
        let flowIns = image.records.filter { $0.name == SignpostName.actionCommit.rawValue && $0.phase == .flowIn }
        #expect(flowIns.map(\.arg1) == [request.flow], "ActionRunInput.flow reached action.commit")
    }
}
