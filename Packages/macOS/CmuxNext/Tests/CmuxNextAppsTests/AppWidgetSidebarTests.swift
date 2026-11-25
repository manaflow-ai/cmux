import AppKit
import CmuxNextDaemon
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
@testable import CmuxNextApps
import Testing

/// The sidebar's widget area: the daemon's layout maps to tiles on the New Tab tile unit (small two
/// per row, medium the full width), each tile mounts `cmux.widget/1` with `{place, size, instance}`,
/// edits go out as the person's `apps.widgets.layout.edit`, the layout is read again on
/// `apps-widgets-changed`, and a widget whose render throws keeps its last scene, marked stale.
@MainActor @Suite(.serialized) struct AppWidgetSidebarTests {
    final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var layout: [AppJSON] = []
        var lists = 0
        var mounted: [(id: String, app: String, interface: String, context: AppJSON)] = []
        var unmounted: [String] = []
        var calls: [(op: String, args: AppJSON, origin: AppOrigin)] = []

        static let manifest: AppJSON = [
            "id": "local/clock", "version": "1.0.0", "publisher": ["name": "local"],
            "implements": ["cmux.widget/1": [
                "export": "renderClock", "title": ["en": "Clock"],
                "options": ["sizes": ["small", "medium"], "defaultSize": "small", "places": ["newtab", "sidebar"]],
            ]],
        ]

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            AppsListReply(revision: 1, apps: [AppRecord(json: ["id": "local/clock", "installed": true, "manifest": Self.manifest])].compactMap { $0 })
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func storeCall(_ op: String, args: AppJSON, origin: AppOrigin) async throws(AppsTransportError) -> AppJSON {
            calls.append((op, args, origin))
            guard op == "apps.widgets.list" else { return .object([:]) }
            lists += 1
            return [
                "widgets": [["app": "local/clock", "title": "Clock", "sizes": ["small", "medium"], "defaultSize": "small", "places": ["sidebar"]]],
                "layout": ["revision": .number(Double(lists)), "sidebar": .array(layout)],
            ]
        }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
            mounted.append((mountID, app, interface, context))
        }
        func unmount(mountID: String) async throws(AppsTransportError) { unmounted.append(mountID) }
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON { .null }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    private static func tile(_ instance: String, _ size: String) -> AppJSON {
        ["instance": .string(instance), "app": "local/clock", "size": .string(size)]
    }

    /// Lets the client's list, the area's read and the mounts they send land.
    private static func settle(_ client: AppsClient) async {
        for _ in 0..<200 {
            await Task.yield()
            await client.tail?.value
        }
    }

    private static func started(layout: [AppJSON]) async -> (Transport, AppsClient, AppWidgetArea) {
        let transport = Transport()
        transport.layout = layout
        let client = AppsClient(transport: transport)
        client.start()
        let area = AppWidgetArea(client: client, place: "sidebar")
        area.start()
        await settle(client)
        return (transport, client, area)
    }

    // MARK: Layout to tiles

    @Test func smallTilesPairUpAndAMediumTakesTheFullWidth() {
        let grid = AppWidgetGrid(gap: 8, inset: 8)
        let (frames, height) = grid.layout([.small, .small, .medium], width: 216)
        // unit = (216 - 16 - 8) / 2 = 96
        #expect(frames == [CGRect(x: 8, y: 0, width: 96, height: 96), CGRect(x: 112, y: 0, width: 96, height: 96),
                           CGRect(x: 8, y: 104, width: 200, height: 96)])
        #expect(height == 200)
    }

    @Test func aMediumAfterALoneSmallStartsANewRowInThePersonsOrder() {
        let grid = AppWidgetGrid(gap: 8, inset: 8)
        let (frames, height) = grid.layout([.small, .medium, .small], width: 216)
        #expect(frames.map(\.origin) == [CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 104), CGPoint(x: 8, y: 208)])
        #expect(height == 304)
        #expect(grid.layout([], width: 216).height == 0, "no tile, no height")
    }

    @Test func aDroppedTileLandsBeforeTheTileItCovers() {
        let grid = AppWidgetGrid(gap: 8, inset: 8)
        let frames = grid.layout([.small, .small, .medium], width: 216).frames
        #expect(grid.dropIndex(at: CGPoint(x: 20, y: 40), in: frames) == 0)
        #expect(grid.dropIndex(at: CGPoint(x: 150, y: 40), in: frames) == 1)
        #expect(grid.dropIndex(at: CGPoint(x: 150, y: 400), in: frames) == 3)
    }

    @Test func theListReplyReadsAsTilesAndSpecs() {
        let reply: AppJSON = [
            "widgets": [["app": "a/clock", "title": "Clock", "sizes": ["small", "medium", "large"], "defaultSize": "large"]],
            "layout": ["revision": 4, "sidebar": [Self.tile("w1", "medium"), Self.tile("w2", "small"), ["instance": "w3"]]],
        ]
        let catalog = AppWidgetCatalog(reply: reply, place: "sidebar")
        #expect(catalog.revision == 4)
        #expect(catalog.tiles == [AppWidgetTile(instance: "w1", app: "local/clock", size: .medium),
                                  AppWidgetTile(instance: "w2", app: "local/clock", size: .small)], "a tile it cannot read is skipped")
        #expect(catalog.spec("a/clock")?.sidebarSizes == [.small, .medium])
        #expect(catalog.spec("a/clock")?.sidebarDefault == .small, "large does not go in the sidebar")
    }

    @Test func editsApplyAheadOfTheirCommit() {
        let tiles = [AppWidgetTile(instance: "w1", app: "a", size: .small), AppWidgetTile(instance: "w2", app: "a", size: .small),
                     AppWidgetTile(instance: "w3", app: "a", size: .medium)]
        #expect(AppWidgetEdit.move(instance: "w3", before: "w1").applied(to: tiles).map(\.instance) == ["w3", "w1", "w2"])
        #expect(AppWidgetEdit.move(instance: "w1", before: nil).applied(to: tiles).map(\.instance) == ["w2", "w3", "w1"])
        #expect(AppWidgetEdit.remove(instance: "w2").applied(to: tiles).map(\.instance) == ["w1", "w3"])
        #expect(AppWidgetEdit.resize(instance: "w1", size: .medium).applied(to: tiles).first?.size == .medium)
        #expect(AppWidgetEdit.add(app: "a", size: .small, before: "w2").json == ["op": "add", "app": "a", "size": "small", "before": "w2"])
    }

    // MARK: The area

    @Test func nothingMountsWhileNoWidgetIsPlaced() async {
        let (transport, _, area) = await Self.started(layout: [])
        #expect(transport.lists >= 1)
        #expect(!area.hasTiles)
        #expect(transport.mounted.isEmpty)
    }

    @Test func eachPlacedTileMountsTheWidgetWithItsPlaceSizeAndInstance() async {
        let (transport, _, area) = await Self.started(layout: [Self.tile("w1", "small"), Self.tile("w2", "medium")])
        #expect(area.tiles.map(\.instance) == ["w1", "w2"])
        #expect(transport.mounted.map(\.interface) == ["cmux.widget/1", "cmux.widget/1"])
        #expect(transport.mounted.map { $0.context["size"]?.stringValue } == ["small", "medium"])
        #expect(transport.mounted.map { $0.context["instance"]?.stringValue } == ["w1", "w2"])
        #expect(transport.mounted.allSatisfy { $0.context["place"]?.stringValue == "sidebar" })
        #expect(transport.mounted.allSatisfy { $0.context["timeZone"]?.stringValue == TimeZone.current.identifier })
        #expect(transport.mounted.allSatisfy { $0.context["locale"]?.stringValue?.contains("_") == false })
    }

    @Test func theLayoutIsReadAgainWhenAnyClientChangesIt() async {
        let (transport, client, area) = await Self.started(layout: [Self.tile("w1", "small")])
        transport.layout = [Self.tile("w1", "medium")]
        transport.onEvent?(.widgetsChanged(revision: 2, place: "newtab"))
        await Self.settle(client)
        #expect(area.tiles.first?.size == .small, "another place's change is not this area's")
        transport.onEvent?(.widgetsChanged(revision: 3, place: "sidebar"))
        await Self.settle(client)
        #expect(area.tiles.first?.size == .medium)
        #expect(transport.unmounted.count == 1, "a resize mounts the widget again at its new size")
        #expect(transport.mounted.last?.context["size"]?.stringValue == "medium")
    }

    @Test func anEditGoesOutAsThePersonsWithAKey() async throws {
        let (transport, client, area) = await Self.started(layout: [Self.tile("w1", "small"), Self.tile("w2", "small")])
        area.edit(.remove(instance: "w1"))
        #expect(area.tiles.map(\.instance) == ["w2"], "the area shows the edit at once")
        await Self.settle(client)
        let edit = try #require(transport.calls.first { $0.op == "apps.widgets.layout.edit" })
        #expect(edit.origin == .user)
        #expect(edit.args["place"]?.stringValue == "sidebar")
        #expect(edit.args["edit"] == ["op": "remove", "instance": "w1"])
        #expect(edit.args["idempotency_key"]?.stringValue?.isEmpty == false)
    }

    @Test func aTileStartsHiddenAndEachChangeIsReportedOnce() async {
        let (transport, client, area) = await Self.started(layout: [Self.tile("w1", "small")])
        area.setVisible(true, instance: "w1")
        area.setVisible(true, instance: "w1")
        area.setVisible(false, instance: "w1")
        area.setVisible(false, instance: "w1")
        area.setVisible(true, instance: "w1")
        await Self.settle(client)
        let visible = transport.calls.filter { $0.op == "apps.widgets.visible" }.map { $0.args["visible"]?.boolValue }
        // Hidden at its mount (no view shows it yet), then each change once.
        #expect(visible == [false, true, false, true])
    }

    @Test func aReconnectKeepsAHiddenTileHiddenAndClearsItsStaleMark() async throws {
        let (transport, client, area) = await Self.started(layout: [Self.tile("w1", "small")])
        let mount = try #require(area.mounted["w1"]?.mount)
        transport.onEvent?(.widgetHealth(mountID: mount.id, stale: true, reason: "render: TypeError", retryMilliseconds: 1000))
        await Self.settle(client)
        transport.calls.removeAll()
        // A new supervisor: every mount is sent again, and it runs a new mount as shown.
        transport.onEvent?(.availability(.available(epoch: 99)))
        await Self.settle(client)
        let visible = transport.calls.filter { $0.op == "apps.widgets.visible" }.map { $0.args["visible"]?.boolValue }
        #expect(visible == [false], "no view showed the tile: it is hidden again on the new supervisor")
        #expect(mount.model.staleReason == nil, "a new supervisor starts with no failures and never says stale: false")
    }

    // MARK: Let it crash

    @Test func aStaleWidgetKeepsItsSceneDimmedAndRecovers() async throws {
        let (transport, client, area) = await Self.started(layout: [Self.tile("w1", "small")])
        let mount = try #require(area.mounted["w1"]?.mount)
        let drawn: AppJSON = [["op": "create", "id": "n1", "type": "Text", "props": ["text": "9:41"]], ["op": "root", "id": "n1"]]
        transport.onEvent?(.scene(mountID: mount.id, ops: AppSceneOp.batch(drawn), reset: false))
        let tile = AppWidgetTileView(instance: "w1", mount: mount)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView?.addSubview(tile)
        #expect(!tile.isStale)

        transport.onEvent?(.widgetHealth(mountID: mount.id, stale: true, reason: "render: TypeError", retryMilliseconds: 1000))
        await Self.settle(client)
        #expect(mount.model.staleReason == "render: TypeError")
        #expect(mount.model.scene.root == "n1", "the last scene stays: never a blank tile")
        #expect(mount.model.status == .ready)
        #expect(tile.isStale)
        #expect(!tile.isRetryHintShown, "a failure under the shared bound says nothing in words")
        #expect(abs(tile.scene.alphaValue - AppWidgetTileView.staleOpacity) < 0.01)

        transport.onEvent?(.widgetHealth(mountID: mount.id, stale: false, reason: nil, retryMilliseconds: nil))
        await Self.settle(client)
        #expect(mount.model.staleReason == nil)
        #expect(!tile.isStale)
        tile.removeFromSuperview()
    }

    /// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up". A widget whose render fails
    /// and retries said "Retrying" at once; now the line waits the shared bound and a quick recovery never draws it.
    @Test func theRetryingLineWaitsTheSharedBoundAndARecoveryInsideItSaysNothing() async throws {
        let (transport, client, area) = await Self.started(layout: [Self.tile("w1", "small")])
        let mount = try #require(area.mounted["w1"]?.mount)
        let clock = ManualClock()
        let tile = AppWidgetTileView(instance: "w1", mount: mount, clock: clock)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView?.addSubview(tile)
        defer { tile.removeFromSuperview() }

        transport.onEvent?(.widgetHealth(mountID: mount.id, stale: true, reason: "render: TypeError", retryMilliseconds: 1000))
        await Self.settle(client)
        #expect(tile.isStale)
        #expect(!tile.isRetryHintShown)
        try await clock.waitForSleeper()
        clock.advance(by: QuietHold.connectionDelay - .milliseconds(1))
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(!tile.isRetryHintShown, "under the bound: still quiet")
        // Recovers inside the bound: no line was ever drawn, and a new failure waits again.
        transport.onEvent?(.widgetHealth(mountID: mount.id, stale: false, reason: nil, retryMilliseconds: nil))
        await Self.settle(client)
        #expect(!tile.isStale && !tile.isRetryHintShown)
        transport.onEvent?(.widgetHealth(mountID: mount.id, stale: true, reason: "render: TypeError", retryMilliseconds: 1000))
        await Self.settle(client)
        try await clock.waitForSleeper()
        clock.advance(by: QuietHold.connectionDelay)
        for _ in 0 ..< 500 where !tile.isRetryHintShown { await Task.yield() }
        #expect(tile.isRetryHintShown, "past the bound the tile says it is retrying")
    }

    @Test func theWidgetEventsDecode() {
        let decoding = AppsWireDecoding()
        #expect(decoding.event(name: "apps-widgets-changed", payload: .object(["revision": .number(3), "place": .string("sidebar")]))
            == .widgetsChanged(revision: 3, place: "sidebar"))
        #expect(decoding.event(name: "apps-widget-health", payload: .object([
            "mount_id": .string("m1"), "stale": .bool(true), "reason": .string("boom"), "retry_ms": .number(2000),
        ])) == .widgetHealth(mountID: "m1", stale: true, reason: "boom", retryMilliseconds: 2000))
    }
}
