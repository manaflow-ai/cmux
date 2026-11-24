import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import Testing

/// The apps' toolbar items (`contributes.toolbarItems`) in the window's top-left band: the daemon's list
/// (`apps.toolbar.list`) draws one built-in-sized button per item, a click runs the item's op through `apps-run`
/// as the person, and a saved manifest (`apps-changed`) redraws the buttons with no relaunch. Nothing is added
/// while no app contributes.
@MainActor @Suite(.serialized) struct AppToolbarButtonsTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var revision: UInt64 = 1
        /// The installed app's `contributes.toolbarItems`.
        var toolbarItems: [AppJSON] = []
        var runs: [(app: String, op: String, origin: AppOrigin)] = []

        private var manifest: AppJSON {
            ["manifestVersion": 2, "id": "local/sync", "name": "Sync", "version": .string("1.0.\(revision)"),
             "contributes": ["toolbarItems": .array(toolbarItems)]]
        }

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            let record = AppRecord(json: ["id": "local/sync", "installed": true, "manifest": manifest])
            return AppsListReply(revision: revision, apps: [record].compactMap { $0 })
        }
        /// Answers `apps.toolbar.list` as the daemon does for this one installed app's buttons
        /// (cmux-tui-core `apps/toolbar.rs`, tested in `supervisor_toolbar_tests.rs`).
        func storeCall(_ op: String) async throws(AppsTransportError) -> AppJSON {
            guard op == "apps.toolbar.list" else { return .object([:]) }
            let items: [AppJSON] = toolbarItems.compactMap { item in
                guard item["kind"]?.stringValue == "button", let id = item["id"], let title = item["title"],
                      let op = item["action"]?["op"] else { return nil }
                return ["app": "local/sync", "extension": "Sync", "id": id, "kind": "button", "title": title,
                        "symbol": item["icon"]?["symbol"] ?? .null, "op": op, "order": 500]
            }
            return ["items": .array(items)]
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {}
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            runs.append((app, op, origin))
            return .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    private static func button(_ id: String) -> AppJSON {
        ["id": .string(id), "kind": "button", "title": .string(id.capitalized), "icon": ["symbol": "arrow.triangle.2.circlepath"],
         "action": ["op": .string("local.sync.\(id)")]]
    }

    private static func settle() async { for _ in 0..<200 { await Task.yield() } }

    /// A started client with the band's buttons following it in `host`.
    private static func following(_ transport: Transport, in host: NSView) async -> (AppsClient, AppToolbarButtons) {
        let client = AppsClient(transport: transport)
        client.start()
        let buttons = AppToolbarButtons()
        buttons.follow(client, in: host, reveal: nil)
        await settle()
        return (client, buttons)
    }

    private static func changed(_ transport: Transport) async {
        transport.revision += 1
        transport.onEvent?(.changed(revision: transport.revision, app: "local/sync"))
        await settle()
    }

    @Test func aManifestWithToolbarItemsAddsOneButtonThatRunsItsOp() async {
        let transport = Transport()
        transport.toolbarItems = [Self.button("sync")]
        let host = NSView()
        let (client, toolbar) = await Self.following(transport, in: host)
        #expect(client.toolbarItems.map(\.op) == ["local.sync.sync"])
        #expect(toolbar.buttons.count == 1)
        #expect(host.subviews.map(ObjectIdentifier.init) == toolbar.buttons.map(ObjectIdentifier.init))
        let button = toolbar.buttons[0]
        #expect(button.symbol == "arrow.triangle.2.circlepath")
        #expect(button.accessibilityLabel() == "Sync")
        #expect(button.accessibilityIdentifier() == "cmux.titlebar.app.local/sync#sync")
        button.performClick(nil)
        await Self.settle()
        #expect(transport.runs.map(\.op) == ["local.sync.sync"])
        #expect(transport.runs.first?.origin == .user)
    }

    @Test func noContributionAddsNoButton() async {
        let host = NSView()
        let (_, toolbar) = await Self.following(Transport(), in: host)
        #expect(toolbar.buttons.isEmpty)
        #expect(host.subviews.isEmpty)
    }

    @Test func aSavedManifestRedrawsTheButtonsWithNoRelaunch() async {
        let transport = Transport()
        transport.toolbarItems = [Self.button("sync")]
        let host = NSView()
        let (_, toolbar) = await Self.following(transport, in: host)
        transport.toolbarItems = [Self.button("sync"), Self.button("pull")]
        await Self.changed(transport)
        #expect(toolbar.buttons.map { $0.accessibilityLabel() } == ["Sync", "Pull"])
        #expect(host.subviews.map(ObjectIdentifier.init) == toolbar.buttons.map(ObjectIdentifier.init))
        transport.toolbarItems = []
        await Self.changed(transport)
        #expect(toolbar.buttons.isEmpty, "a save that drops them leaves the built-in band")
        #expect(host.subviews.isEmpty)
    }

    @Test func itemsPastTheVisibleOnesGoInOneOverflowButton() async {
        let transport = Transport()
        transport.toolbarItems = ["a", "b", "c", "d"].map(Self.button)
        let (_, toolbar) = await Self.following(transport, in: NSView())
        #expect(toolbar.buttons.count == AppToolbarButtons.visibleItems)
        #expect(toolbar.buttons.last?.accessibilityIdentifier() == "cmux.titlebar.app.overflow")
        #expect(toolbar.buttons.last?.pressMenu?()?.items.map(\.title) == ["C", "D"])
    }
}
