import CmuxNextAgentPane
@testable import CmuxNextApps
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Session Info app sections on the agent page: `cmux.apps.panels.*` forwards to the app
/// supervisor, and a closed page ends its mounts.
@MainActor @Suite struct AppsPanelsPageProviderTests {
    private static let page = PageCallContext(page: PageDescriptor.agent.id)
    private static let click = PageCallContext(page: PageDescriptor.agent.id, userGesture: true, gestureEvent: 1)

    @Test func onlyTheAgentAndStorePagesAdmitPanels() {
        #expect(PageDescriptor.agent.admits("cmux.apps.panels.mount"))
        #expect(!PageDescriptor.agent.admits("cmux.apps.install"), "the agent page gets the panel ops only")
        #expect(PageDescriptor.apps.admits("cmux.apps.panels.list"))
        #expect(!PageDescriptor.settings.admits("cmux.apps.panels.list"))
    }

    @Test func forwardsListMountSceneDispatchAndUnmountsOnClose() async throws {
        let transport = FakePanelsTransport()
        let client = AppsClient(transport: transport)
        client.start()
        for _ in 0..<100 where !client.hasList { await Task.yield() }
        try #require(client.hasList)
        let provider = AppsPanelsPageProvider(client: client)

        let listed = try await provider.call("cmux.apps.panels.list", params: .object([:]), context: Self.page)
        #expect(listed["panels"]?.arrayValue?.first?["app"]?.stringValue == "local/customize")
        #expect(listed["panels"]?.arrayValue?.first?["section"]?.stringValue == "prs")

        let mounted = try await provider.call("cmux.apps.panels.mount", params: .object([
            "surface": "sessionInfoSection", "app": "local/customize", "section": "prs",
            "context": .object(["session_id": "s1", "cwd": "/tmp/repo", "branch": "main"]),
        ]), context: Self.page)
        let mountID = try #require(mounted["mount_id"]?.stringValue)
        await client.tail?.value
        let sent = try #require(transport.mounts.first)
        #expect(sent.interface == "cmux.session.info.section/1")
        #expect(sent.context["session_id"]?.stringValue == "s1")
        #expect(sent.context["cwd"]?.stringValue == "/tmp/repo")
        #expect(sent.context["surface"]?.stringValue == "sessionInfoSection")

        // Ops that land before the page subscribes reach its first subscriber as a reset, then the
        // mount's current status.
        transport.onEvent?(.scene(mountID: mountID, ops: [.root(id: "n1")]))
        let box = Heard()
        let subscription = try await provider.subscribe("cmux.apps.panels.scene", filter: .object(["mount_id": .string(mountID)]),
                                                        context: Self.page) { box.events.append($0) }
        #expect(box.events.count == 2)
        #expect(box.events.first?["reset"]?.boolValue == true)
        #expect(box.events.first?["ops"]?.arrayValue?.first?["op"]?.stringValue == "root")
        #expect(box.events.last?["status"]?.stringValue == "loading")
        transport.onEvent?(.scene(mountID: mountID, ops: [.remove(id: "n1")]))
        #expect(box.events.count == 3)
        #expect(box.events.last?["reset"] == nil)
        #expect(box.events.last?["ops"] != nil)
        _ = subscription

        let dispatch: JSONValue = .object(["mount_id": .string(mountID), "node": "n1", "event": "tap"])
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.apps.panels.dispatch", params: dispatch, context: Self.page)
        }
        _ = try await provider.call("cmux.apps.panels.dispatch", params: dispatch, context: Self.click)
        await client.tail?.value
        #expect(transport.dispatches == ["\(mountID) n1 tap"])

        let router = PageRouter(descriptor: .agent, routes: [PageRoute(prefix: AppsPanelsPageProvider.namespace, provider: provider)])
        router.close()
        await client.tail?.value
        #expect(transport.unmounts == [mountID])
    }

    /// A started client over `transport`, its list landed.
    private static func listedClient(_ transport: FakePanelsTransport) async throws -> AppsClient {
        let client = AppsClient(transport: transport)
        client.start()
        for _ in 0..<100 where !client.hasList { await Task.yield() }
        try #require(client.hasList)
        return client
    }

    private static func mount(_ provider: AppsPanelsPageProvider, surface: String, app: String = "local/customize",
                              section: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["surface": .string(surface), "app": .string(app), "context": .object(["session_id": "s1"])]
        if let section { params["section"] = .string(section) }
        return try await provider.call("cmux.apps.panels.mount", params: .object(params), context: Self.page)
    }

    @Test func mountResolvesEachSurfaceAsItsNativeHostDoes() async throws {
        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface())
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)

        for (surface, section, interface) in [
            ("pane", nil, "cmux.pane/1"),
            ("sidebarSection", "cmux.section/1", "cmux.section/1"),
            // A single scene section answers any id, as the sidebar resolves it.
            ("sidebarSection", "other", "cmux.section/1"),
            ("hoverCard", nil, "cmux.hovercard/1"),
            ("sessionInfoSection", "cmux.session.info.section/1", "cmux.session.info.section/1"),
        ] as [(String, String?, String)] {
            let reply = try await Self.mount(provider, surface: surface, section: section)
            #expect(reply["mount_id"]?.stringValue != nil)
            await client.tail?.value
            #expect(transport.mounts.last?.interface == interface)
            #expect(transport.mounts.last?.context["surface"]?.stringValue == surface)
        }

        // A surface the page does not name, a missing section and an unknown app are refused.
        await #expect(throws: PageError.self) { try await Self.mount(provider, surface: "statusItem") }
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.apps.panels.mount", params: .object(["app": "local/customize", "context": .object([:])]), context: Self.page)
        }
        await #expect(throws: PageError.self) { try await Self.mount(provider, surface: "sessionInfoSection") }
        await #expect(throws: PageError.self) { try await Self.mount(provider, surface: "pane", app: "local/missing") }
    }

    @Test func hoverCardMountsOnlyTheUsersOwnApp() async throws {
        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface(id: "local/other"))
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)
        await #expect(throws: PageError.self) { try await Self.mount(provider, surface: "hoverCard", app: "local/other") }
        #expect(try await Self.mount(provider, surface: "pane", app: "local/other")["mount_id"] != nil)
    }

    @Test func forwardsEachStatusChangeOnTheSceneStream() async throws {
        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface())
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)
        let mountID = try #require(try await Self.mount(provider, surface: "pane")["mount_id"]?.stringValue)
        await client.tail?.value
        let box = Heard()
        let subscription = try await provider.subscribe("cmux.apps.panels.scene", filter: .object(["mount_id": .string(mountID)]),
                                                        context: Self.page) { box.events.append($0) }
        #expect(box.events.map { $0["status"]?.stringValue } == ["loading"])

        transport.onEvent?(.scene(mountID: mountID, ops: [.create(id: "t", type: "Text", props: ["text": "Hi"]), .root(id: "t")]))
        #expect(box.events.last?["status"]?.stringValue == "ready")
        #expect(box.events.dropLast().last?["ops"] != nil, "the scene goes out before the status it caused")

        transport.onEvent?(.mountFailed(mountID: mountID, reason: "init: Error: nope"))
        #expect(box.events.last?["status"]?.stringValue == "failed")
        #expect(box.events.last?["reason"]?.stringValue == "init: Error: nope")
        let count = box.events.count
        // The same status again sends nothing.
        transport.onEvent?(.mountFailed(mountID: mountID, reason: "init: Error: nope"))
        #expect(box.events.count == count)

        transport.availability = .unavailable(.notConnected)
        transport.onEvent?(.availability(.unavailable(.notConnected)))
        #expect(box.events.last?["status"]?.stringValue == "disconnected")
        #expect(box.events.last?["reason"]?.stringValue?.isEmpty == false)
        #expect(box.events.allSatisfy { $0["mount_id"]?.stringValue == mountID })
        _ = subscription
    }

    /// A saved script that does not load keeps every drawn view of the app on the script before it
    /// (``AppSceneModel/reloadFailure``): each surface's page hears the refused save, a page that
    /// subscribes later hears it too, and the next good save's reset scene clears it.
    @Test func forwardsAndClearsTheRefusedSaveOnEverySurface() async throws {
        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface())
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)
        let reason = "init: SyntaxError: expecting ';' at main.js:2:12"
        let drawn: [AppSceneOp] = [.create(id: "t", type: "Text", props: ["text": "Hi"]), .root(id: "t")]
        var heard: [(mountID: String, box: Heard, subscription: PageSubscription)] = []
        for (surface, section) in [("pane", nil), ("sessionInfoSection", "cmux.session.info.section/1"),
                                   ("sidebarSection", "cmux.section/1"), ("hoverCard", nil)] as [(String, String?)] {
            let mountID = try #require(try await Self.mount(provider, surface: surface, section: section)["mount_id"]?.stringValue)
            await client.tail?.value
            let box = Heard()
            let subscription = try await provider.subscribe("cmux.apps.panels.scene", filter: .object(["mount_id": .string(mountID)]),
                                                            context: Self.page) { box.events.append($0) }
            #expect(!box.events.contains { $0["reload_failure"] != nil }, "a mount with no refused save says nothing of one")
            transport.onEvent?(.scene(mountID: mountID, ops: drawn))
            #expect(box.events.last?["status"]?.stringValue == "ready")
            heard.append((mountID, box, subscription))
        }

        transport.onEvent?(.reloadFailed(app: "local/customize", reason: reason))
        for (mountID, box, _) in heard {
            #expect(box.events.last?["mount_id"]?.stringValue == mountID)
            #expect(box.events.last?["reload_failure"]?["reason"]?.stringValue == reason)
            let count = box.events.count
            // The same refused save again sends nothing.
            transport.onEvent?(.reloadFailed(app: "local/customize", reason: reason))
            #expect(box.events.count == count)
        }

        // A page that subscribes after the refused save hears it with the status.
        let (paneID, _, _) = try #require(heard.first)
        let late = Heard()
        let lateSubscription = try await provider.subscribe("cmux.apps.panels.scene", filter: .object(["mount_id": .string(paneID)]),
                                                            context: Self.page) { late.events.append($0) }
        #expect(late.events.map { $0["status"]?.stringValue } == ["ready", nil])
        #expect(late.events.last?["reload_failure"]?["reason"]?.stringValue == reason)

        // The next good save resets the scene: the mark goes, after the scene that replaced it.
        transport.onEvent?(.scene(mountID: paneID, ops: drawn, reset: true))
        #expect(late.events.last?["reload_failure"] == .null)
        #expect(late.events.dropLast().last?["ops"] != nil)
        #expect(heard.first?.box.events.last?["reload_failure"] == .null)
        _ = (heard, lateSubscription)
    }

    @Test func reloadIsGestureOnlyAndMountsTheAppAgain() async throws {
        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface())
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)
        let mountID = try #require(try await Self.mount(provider, surface: "pane")["mount_id"]?.stringValue)
        await client.tail?.value
        let box = Heard()
        let subscription = try await provider.subscribe("cmux.apps.panels.scene", filter: .object(["mount_id": .string(mountID)]),
                                                        context: Self.page) { box.events.append($0) }
        transport.onEvent?(.mountFailed(mountID: mountID, reason: "init: Error: nope"))
        #expect(box.events.last?["status"]?.stringValue == "failed")
        let mounted = transport.mounts.count

        let reload: JSONValue = .object(["mount_id": .string(mountID)])
        await #expect(throws: PageError.self) { try await provider.call("cmux.apps.panels.reload", params: reload, context: Self.page) }
        await client.tail?.value
        #expect(transport.mounts.count == mounted, "a reload without the person's gesture runs nothing")

        _ = try await provider.call("cmux.apps.panels.reload", params: reload, context: Self.click)
        await client.tail?.value
        #expect(transport.mounts.count == mounted + 1)
        // The failed view loads again; no supervisor event says so, the model does.
        for _ in 0..<100 where box.events.last?["status"]?.stringValue != "loading" { await Task.yield() }
        #expect(box.events.last?["status"]?.stringValue == "loading")

        await #expect(throws: PageError.self) {
            try await provider.call("cmux.apps.panels.reload", params: .object(["mount_id": "nope"]), context: Self.click)
        }
        _ = subscription
    }

    @Test func layoutKeepsEachMountsReportedHeight() async throws {
        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface())
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)
        let heard = Heard()
        provider.onLayout = { heard.events.append(.string("\($0) \($1)")) }
        let mountID = try #require(try await Self.mount(provider, surface: "sidebarSection", section: "cmux.section/1")["mount_id"]?.stringValue)
        #expect(provider.reportedHeight(mountID: mountID) == nil)

        for height in [120.0, 120.0, 64.0] {
            _ = try await provider.call("cmux.apps.panels.layout", params: .object(["mount_id": .string(mountID), "height": .number(height)]),
                                        context: Self.page)
        }
        #expect(provider.reportedHeight(mountID: mountID) == 64)
        #expect(heard.events == [.string("\(mountID) 120.0"), .string("\(mountID) 64.0")])

        await #expect(throws: PageError.self) {
            try await provider.call("cmux.apps.panels.layout", params: .object(["mount_id": .string(mountID), "height": .number(-1)]), context: Self.page)
        }
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.apps.panels.layout", params: .object(["mount_id": "nope", "height": .number(10)]), context: Self.page)
        }
        _ = try await provider.call("cmux.apps.panels.unmount", params: .object(["mount_id": .string(mountID)]), context: Self.page)
        #expect(provider.reportedHeight(mountID: mountID) == nil)
    }

    @Test func servesOnlyImagesInsideTheMountsBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "panels-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle.appending(path: "assets", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: bundle.appending(path: "assets/logo one.png"))
        try Data("secret".utf8).write(to: root.appending(path: "outside.png"))
        try Data("text".utf8).write(to: bundle.appending(path: "notes.txt"))
        try FileManager.default.createSymbolicLink(at: bundle.appending(path: "escape.png"), withDestinationURL: root.appending(path: "outside.png"))

        let transport = FakePanelsTransport(manifest: FakePanelsTransport.everySurface(), bundleDirectory: bundle.path)
        let client = try await Self.listedClient(transport)
        let provider = AppsPanelsPageProvider(client: client)
        // A page whose host does not serve the prefixes gets no asset or symbol base.
        let unserved = try await Self.mount(provider, surface: "pane")
        #expect(unserved["asset_base"] == nil && unserved["symbol_base"] == nil)
        provider.servesBundleImages = true
        let reply = try await Self.mount(provider, surface: "pane")
        let mountID = try #require(reply["mount_id"]?.stringValue)
        #expect(reply["asset_base"]?.stringValue == "/__appbundle/\(mountID)/")
        #expect(reply["symbol_base"]?.stringValue == "/__appsymbol/")
        #expect(PageDescriptor.agent.dynamicPrefixes.contains(AppsPanelsPageProvider.bundlePrefix))

        func get(_ path: [String]) async -> PageResource? {
            // The provider reads the checked path, never the URL.
            await provider.resource(for: PageResourceRequest(prefix: AppsPanelsPageProvider.bundlePrefix, path: path,
                                                             url: URL(fileURLWithPath: "/")))
        }
        let image = await get([mountID, "assets", "logo%20one.png"])
        #expect(image?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(image?.mimeType == "image/png")
        #expect(await get([mountID, "%2E%2E", "outside.png"]) == nil, "encoded traversal")
        #expect(await get([mountID, "assets%2F..%2F..%2Foutside.png"]) == nil, "an encoded separator")
        #expect(await get([mountID, "escape.png"]) == nil, "a symlink out of the bundle")
        #expect(await get([mountID, "notes.txt"]) == nil, "only images")
        #expect(await get(["mnt-someone-else", "assets", "logo%20one.png"]) == nil, "another page's mount")

        // Any SF Symbol a scene names, as the native renderer draws it (AppSceneSymbolImages).
        func symbol(_ path: [String]) async -> PageResource? {
            await provider.resource(for: PageResourceRequest(prefix: AppsPanelsPageProvider.symbolPrefix, path: path,
                                                             url: URL(fileURLWithPath: "/")))
        }
        let cup = await symbol(["cup.and.saucer.png"])
        #expect(cup?.mimeType == "image/png" && cup?.data.isEmpty == false)
        #expect(await symbol(["cup.and.saucer"]) == nil, "only .png")
        #expect(await symbol(["%2E%2E%2Fsecret.png"]) == nil, "not a symbol name")
        #expect(await symbol([mountID, "cup.and.saucer.png"]) == nil, "one component")
    }
}

@MainActor
private final class Heard {
    var events: [JSONValue] = []
}

@MainActor
private final class FakePanelsTransport: AppsTransport {
    var availability: AppsAvailability = .available(epoch: 1)
    private let manifest: AppJSON
    private let bundleDirectory: String?

    init(manifest: AppJSON = FakePanelsTransport.sessionInfo, bundleDirectory: String? = nil) {
        self.manifest = manifest
        self.bundleDirectory = bundleDirectory
    }
    var onEvent: ((AppsTransportEvent) -> Void)?
    var mounts: [(interface: String, context: AppJSON)] = []
    var unmounts: [String] = []
    var dispatches: [String] = []

    /// One implementation of each surface's interface, by the user's own app.
    static func everySurface(id: String = "local/customize") -> AppJSON { [
        "id": .string(id), "version": "1.0.0", "manifestVersion": 2, "publisher": ["name": "local"],
        "implements": [
            "cmux.pane/1": ["export": "renderPane"],
            "cmux.section/1": ["export": "renderSection"],
            "cmux.hovercard/1": ["export": "renderCard"],
            "cmux.session.info.section/1": ["export": "renderInfo"],
        ],
    ] }

    static let sessionInfo: AppJSON = [
        "id": "local/customize", "version": "1.0.0", "publisher": ["name": "local"],
        "contributes": ["sessionInfoSections": [["id": "prs", "title": "PRs", "render": "renderPRs"]]],
    ]

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply {
        var record: [String: AppJSON] = ["id": manifest["id"] ?? "local/customize", "installed": true, "manifest": manifest]
        if let bundleDirectory { record["bundle_dir"] = .string(bundleDirectory) }
        return AppsListReply(revision: 1, apps: [AppRecord(json: .object(record))].compactMap { $0 })
    }
    func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] {
        [AppSessionInfoPanel(json: ["app": "local/customize", "section": "prs", "title": "PRs"])].compactMap { $0 }
    }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        throw AppsTransportError(message: "unused")
    }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
        mounts.append((interface, context))
    }
    func unmount(mountID: String) async throws(AppsTransportError) { unmounts.append(mountID) }
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {
        dispatches.append("\(mountID) \(node) \(event)")
    }
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        .null
    }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
}
