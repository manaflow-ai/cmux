@testable import CmuxNextApps
import Foundation
import Testing

/// Extension status items (`cmux.status/1`): the daemon lists them (`apps.status.list`) and the Mac
/// mounts and draws only those. Nothing shows unless an app contributes one, and the list an
/// `apps-changed` brings back moves an item (titlebar to menu bar) with no relaunch.
@MainActor @Suite(.serialized) struct AppStatusItemsTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var items: [AppJSON] = []
        var mounted: [String] = []
        var unmounted: [String] = []

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply { AppsListReply(revision: 1, apps: []) }
        func storeCall(_ op: String) async throws(AppsTransportError) -> AppJSON {
            op == "apps.status.list" ? ["items": .array(items)] : .object([:])
        }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
            mounted.append("\(app) \(interface) \(context["surface"]?.stringValue ?? "")")
        }
        func unmount(mountID: String) async throws(AppsTransportError) { unmounted.append(mountID) }
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    @MainActor private final class Counter { var count = 0 }

    private static func settle() async { for _ in 0..<100 { await Task.yield() } }

    private static func item(_ place: String, title: String = "Health") -> AppJSON {
        ["app": "local/probe", "extension": "Probe", "title": .string(title), "symbol": "bolt", "placement": .string(place), "place": .string(place)]
    }

    @Test func nothingShowsUnlessAnAppContributesAnItem() async {
        let transport = Transport()
        let client = AppsClient(transport: transport)
        client.start()
        let items = AppStatusItems(client: client)
        items.start()
        await Self.settle()
        #expect(items.entries.isEmpty)
        #expect(transport.mounted.isEmpty)
        #expect(items.menuBarRows().isEmpty)
    }

    @Test func aListedItemMountsOnceAndASavedPlacementMovesItLive() async {
        let transport = Transport()
        transport.items = [Self.item("titlebar")]
        let client = AppsClient(transport: transport)
        client.start()
        let items = AppStatusItems(client: client)
        let changes = Counter()
        items.observe(owner: transport) { changes.count += 1 }
        items.start()
        await Self.settle()
        #expect(items.entries(at: .titlebar).map(\.item.app) == ["local/probe"])
        #expect(items.entries(at: .menuBar).isEmpty)
        #expect(transport.mounted == ["local/probe cmux.status/1 statusItem"])

        // The extension's manifest is saved with `placement: menuBar`: the daemon says apps-changed.
        transport.items = [Self.item("menuBar", title: "Health Now")]
        transport.onEvent?(.changed(revision: 2, app: "local/probe"))
        await Self.settle()
        #expect(items.entries(at: .titlebar).isEmpty)
        #expect(items.entries(at: .menuBar).map(\.item.title) == ["Health Now"])
        #expect(transport.mounted.count == 1, "the same mount moves; its scene keeps drawing")
        #expect(changes.count == 2)

        // Uninstalled or hidden: the daemon lists nothing, and the mount ends.
        transport.items = []
        transport.onEvent?(.changed(revision: 3))
        await Self.settle()
        #expect(items.entries.isEmpty)
        #expect(transport.unmounted.count == 1)
    }

    @Test func anItemWithAnUnknownPlaceIsDropped() {
        #expect(AppStatusItem.list(["items": [["app": "a", "title": "A", "place": "dock"]]]).isEmpty)
        #expect(AppStatusItem.list(["items": [Self.item("titlebar")]]).map(\.place) == [.titlebar])
    }
}
