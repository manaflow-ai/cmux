import AppKit
import CmuxNextActions
@testable import CmuxNextApps
import Testing

/// `contributes.menus` rows are registry rows (Lawrence: a menu row runs a registered action, never an
/// inline selector): each runs `app.menu.run` with its app, item and the right-clicked object, and a
/// click runs the app's op on that object as the person.
@MainActor @Suite(.serialized) struct AppMenuRunTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var runs: [(app: String, op: String, args: AppJSON, origin: AppOrigin)] = []

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            let row: AppJSON = ["id": "copy", "target": "workspace", "title": "Copy Branch", "op": "local.branchy.copy_branch",
                                "args": ["format": "short"], "icon": ["symbol": "doc.on.doc"]]
            let manifest: AppJSON = ["id": "local/branchy", "version": "1.0.0", "contributes": ["menus": [row]]]
            let apps = [AppRecord(json: ["id": "local/branchy", "installed": true, "manifest": manifest])]
            return AppsListReply(revision: 1, apps: apps.compactMap { $0 })
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

    private static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// The catalog with `app.menu.run` (the pinned app FFI gains it with the re-pin after the catalog change).
    private static func registry() -> ActionRegistry {
        var catalog = ActionCatalog.all
        if !catalog.contains(where: { $0.id == "app.menu.run" }) {
            catalog.append(ActionDescriptor(id: "app.menu.run", title: "Run App Menu Item", category: .settings,
                                            surfaces: [.contextMenu], targets: [.workspace, .tab]))
        }
        return ActionRegistry(catalog: catalog)
    }

    @Test func aRowIsTheRegistrysAndAClickRunsTheOpAsThePerson() async throws {
        let transport = Transport()
        let client = AppsClient(transport: transport)
        client.start()
        await Self.settle()
        let registry = Self.registry()
        client.installMenuRows(in: registry)
        let target = ActionTargetRef(kind: .workspace, id: "ws1")
        let items = registry.contributedMenuItems?(.workspaceRow, target) ?? []
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == "Copy Branch")
        #expect(item.identifier?.rawValue == "app-menu:local/branchy#copy")
        let run = try #require(ActionRegistry.menuRun(of: item))
        #expect(run.id == "app.menu.run")
        #expect(run.target == target)
        #expect(run.arguments == ["app": .string("local/branchy"), "item": .string("copy")])

        let action = try #require(item.action)
        let handler = try #require(item.target as? NSObject)
        handler.perform(action, with: item)
        await Self.settle()
        #expect(transport.runs.count == 1)
        #expect(transport.runs.first?.app == "local/branchy")
        #expect(transport.runs.first?.op == "local.branchy.copy_branch")
        #expect(transport.runs.first?.origin == .user)
        #expect(transport.runs.first?.args == ["format": "short", "target": ["kind": "workspace", "id": "ws1"]])
    }

    @Test func aRowNoAppHasNowRunsNothing() async {
        let transport = Transport()
        let client = AppsClient(transport: transport)
        client.start()
        await Self.settle()
        let registry = Self.registry()
        client.installMenuRows(in: registry)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: "ws1"),
                                          arguments: ["app": .string("local/branchy"), "item": .string("gone")])
        _ = registry.perform("app.menu.run", invocation: invocation)
        await Self.settle()
        #expect(transport.runs.isEmpty)
    }
}
