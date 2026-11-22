@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// u18462 (Oct 30): "no matter what opens them need cli/mcp/cmd shift p for opening in editor".
/// `cmux open --as-text FILE` sends `file.open` with `as_text`; the socket method hands it to the
/// `file.open` action as `asText`, so HTML, SVG and Markdown open as their source in the code
/// editor from a script or an agent too. Without the flag nothing extra is sent.
@Suite(.timeLimit(.minutes(1))) struct FileOpenAsTextControlTests {
    private static func snapshot() -> ControlSnapshot {
        var snapshot = BrowserOpenSplitTests.snapshot()
        func argument(_ name: String, _ kind: ControlArgumentInfo.Kind) -> ControlArgumentInfo {
            ControlArgumentInfo(name: name, title: name, kind: kind, isRequired: false)
        }
        let open = ControlActionInfo(id: "file.open", title: "Open File…", category: "pane", categoryTitle: "Panes", cliName: "file open",
                                     symbol: "doc", keywords: [], shortcut: nil, shortcutConfig: nil,
                                     arguments: [argument("path", .string), argument("asText", .bool)], targets: ["pane"], requiresMask: 0,
                                     requires: [], isBound: true, isDebugOnly: false, mainMenu: nil)
        let catalog = snapshot.catalog
        snapshot.catalog = ControlCatalog(actions: catalog.actions + [open], contextMask: catalog.contextMask, aliases: catalog.aliases,
                                          targetKinds: catalog.targetKinds, debugActionsAvailable: catalog.debugActionsAvailable)
        return snapshot
    }

    private func open(_ params: [String: JSONValue]) async -> (Result<JSONValue, ControlError>, [ControlActionRequest]) {
        let executor = OpenBrowserExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = Self.snapshot() }
        executor.router.withLock { $0 = router }
        let reply = await router.handle(ControlRequest(id: "1", method: "file.open", params: params))
        return (reply, executor.all)
    }

    @Test func asTextReachesTheFileOpenAction() async throws {
        let (reply, runs) = await open(["paths": ["/tmp/site/index.html", "/tmp/site/README.md"], "as_text": true])
        _ = try reply.get()
        #expect(runs.map(\.actionID) == ["file.open", "file.open"])
        #expect(runs.allSatisfy { $0.arguments["asText"] == .bool(true) }, "\(runs.map(\.arguments))")
    }

    @Test func withoutAsTextTheOpenRendersAsBefore() async throws {
        let (reply, runs) = await open(["path": "/tmp/site/index.html"])
        _ = try reply.get()
        #expect(runs.count == 1)
        #expect(runs.first?.arguments["asText"] == nil)
    }

    @Test func aNonBooleanAsTextIsRefused() async {
        let (reply, runs) = await open(["path": "/tmp/site/index.html", "as_text": "yes"])
        guard case .failure(let error) = reply else {
            Issue.record("expected invalid params, got \(reply)")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(runs.isEmpty)
    }
}
