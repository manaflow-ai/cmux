import AppKit
@testable import CmuxNextApps
import Testing

/// `contributes.menus`: the rows apps add to cmux's own right-click menus (workspace row, tab,
/// terminal). A menu reads them from the install mirror at each open, so a saved manifest shows on
/// the next right-click once `apps-changed` lists again, with no relaunch.
@MainActor @Suite(.serialized) struct AppMenuContributionTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var revision: UInt64 = 1
        var menus: AppJSON = []
        var hidden = false
        var runs: [(app: String, op: String, args: AppJSON, origin: AppOrigin)] = []

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            let manifest: AppJSON = ["id": "local/branchy", "version": "1.0.0", "contributes": ["menus": menus]]
            let apps = [AppRecord(json: ["id": "local/branchy", "installed": true, "hidden": .bool(hidden), "manifest": manifest])]
            return AppsListReply(revision: revision, apps: apps.compactMap { $0 })
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {}
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            runs.append((app, op, args, origin))
            return .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    private static func row(_ id: String, _ target: String, _ title: String, order: Int? = nil) -> AppJSON {
        var row: AppJSON = ["id": .string(id), "target": .string(target), "title": .string(title), "op": "local.branchy.copy_branch",
                            "args": ["format": "short"]]
        if let order { row["order"] = .number(Double(order)) }
        return row
    }

    private static func settle(_ client: AppsClient) async {
        for _ in 0..<100 { await Task.yield() }
    }

    private static func started(_ transport: Transport) async -> AppsClient {
        let client = AppsClient(transport: transport)
        client.start()
        await settle(client)
        return client
    }

    private static func titles(_ client: AppsClient, _ target: AppMenuItem.Target) -> [String] {
        client.menuItems(for: target, kind: "workspace", id: "ws1").map(\.title)
    }

    @Test func eachMenuListsItsOwnRowsInOrder() async {
        let transport = Transport()
        transport.menus = [Self.row("b", "workspace", "Second"), Self.row("a", "workspace", "First", order: 1),
                           Self.row("t", "tab", "Tab Row"), Self.row("x", "chat", "Chat Row")]
        let client = await Self.started(transport)
        #expect(Self.titles(client, .workspace) == ["First", "Second"])
        #expect(Self.titles(client, .tab) == ["Tab Row"])
        #expect(Self.titles(client, .terminal).isEmpty)
    }

    @Test func onlyTheWorkspaceTabAndTerminalMenusTakeAppRows() {
        #expect(AppMenuItem.Target(menuContext: "workspaceRow") == .workspace)
        #expect(AppMenuItem.Target(menuContext: "tab") == .tab)
        #expect(AppMenuItem.Target(menuContext: "terminalSelection") == .terminal)
        for chat in ["agentChat", "priorityRow", "workspaceGroup", "pane", "browserPage"] {
            #expect(AppMenuItem.Target(menuContext: chat) == nil)
        }
    }

    @Test func aHiddenAppAddsNoRows() async {
        let transport = Transport()
        transport.menus = [Self.row("a", "workspace", "Copy Branch")]
        transport.hidden = true
        let client = await Self.started(transport)
        #expect(Self.titles(client, .workspace).isEmpty)
    }

    @Test func aSavedManifestChangesTheRowsOnAppsChangedWithNoRelaunch() async {
        let transport = Transport()
        transport.menus = [Self.row("copy", "workspace", "Copy Branch")]
        let client = await Self.started(transport)
        #expect(Self.titles(client, .workspace) == ["Copy Branch"])
        // The extension's manifest is saved: the supervisor reloads it and says apps-changed.
        transport.menus = [Self.row("copy", "workspace", "Copy Branch Name"), Self.row("open", "terminal", "Open PR")]
        transport.revision = 2
        transport.onEvent?(.changed(revision: 2))
        await Self.settle(client)
        #expect(Self.titles(client, .workspace) == ["Copy Branch Name"])
        #expect(Self.titles(client, .terminal) == ["Open PR"])
        // And a save that drops the row takes it out of the menu.
        transport.menus = []
        transport.revision = 3
        transport.onEvent?(.changed(revision: 3))
        await Self.settle(client)
        #expect(Self.titles(client, .workspace).isEmpty)
    }

    @Test func aClickRunsTheOpOnTheRightClickedObjectAsThePerson() async throws {
        let transport = Transport()
        transport.menus = [Self.row("copy", "workspace", "Copy Branch")]
        let client = await Self.started(transport)
        let item = try #require(client.menuItems(for: .workspace, kind: "workspace", id: "ws1").first)
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        target.perform(action, with: item)
        await Self.settle(client)
        #expect(transport.runs.count == 1)
        #expect(transport.runs.first?.app == "local/branchy")
        #expect(transport.runs.first?.op == "local.branchy.copy_branch")
        #expect(transport.runs.first?.origin == .user)
        #expect(transport.runs.first?.args == ["format": "short", "target": ["kind": "workspace", "id": "ws1"]])
    }
}
