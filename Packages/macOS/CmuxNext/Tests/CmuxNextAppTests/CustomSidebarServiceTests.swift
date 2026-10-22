@testable import CmuxNextApps
import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing

/// The custom sidebar is opt in and costs nothing until the user's own app implements
/// `cmux.sidebar/1` (plans/cmux-next/custom-sidebar-DESIGN.md): no mount, no app-host VM, no view.
@MainActor
@Suite(.serialized) struct CustomSidebarServiceTests {
    static func record(implements: [String: String]) throws -> AppRecord {
        let manifest: AppJSON = [
            "manifestVersion": 2, "id": "local/customize", "name": ["en": "My sidebar"], "version": "1.0.0",
            "runtime": ["main": "main.js"],
            "implements": .object(implements.mapValues { ["export": .string($0)] }),
            "scopes": ["workspace:read": "Rows"],
        ]
        return try #require(AppRecord(json: ["id": "local/customize", "installed": true, "manifest": manifest]))
    }

    /// Starts a client on `transport` and waits for its first list.
    static func listed(_ transport: CustomSidebarTransport) async -> AppsClient {
        let client = AppsClient(transport: transport)
        client.start()
        for await listed in ObservationStream({ client.hasList }) where listed { break }
        return client
    }

    @Test func noScriptMountsNothing() async throws {
        let transport = CustomSidebarTransport(apps: [try Self.record(implements: ["cmux.sidebar.rows/1": "decorateRows"])])
        let client = await Self.listed(transport)
        let service = SidebarCustomizationService(client: client) { _ in true }
        // The rows mount is the service's first and only mount; the sidebar one never comes.
        let first = await transport.nextMount()
        #expect(first == "cmux.sidebar.rows/1")
        #expect(service.customSidebar == nil)
        #expect(transport.interfaces == ["cmux.sidebar.rows/1"], "no custom sidebar mount: \(transport.interfaces)")
    }

    @Test func aScriptReplacesTheListWithOneMount() async throws {
        let transport = CustomSidebarTransport(apps: [try Self.record(implements: ["cmux.sidebar/1": "sidebar"])])
        let client = await Self.listed(transport)
        let service = SidebarCustomizationService(client: client) { _ in true }
        let first = await transport.nextMount()
        #expect(first == "cmux.sidebar/1")
        let content = try #require(service.customSidebar)
        #expect(transport.surfaces == ["customSidebar"])
        // The first scene arrives: the content is ready and shows the script's view.
        let mountID = try #require(transport.mountIDs.first)
        transport.onEvent?(.scene(mountID: mountID, ops: [.create(id: "t", type: "Text", props: ["text": "hi"]), .root(id: "t")]))
        #expect(content.isReady)
        #expect(content.errorText == nil)
    }
}

/// An app supervisor that lists `apps` and records mounts.
final class CustomSidebarTransport: AppsTransport {
    let apps: [AppRecord]
    var availability: AppsAvailability { .available(epoch: 1) }
    var onEvent: ((AppsTransportEvent) -> Void)?
    private(set) var interfaces: [String] = []
    private(set) var surfaces: [String] = []
    private(set) var mountIDs: [String] = []
    private let mounts: AsyncStream<String>
    private let mounted: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.Iterator?

    init(apps: [AppRecord]) {
        self.apps = apps
        (mounts, mounted) = AsyncStream.makeStream(of: String.self)
    }

    /// The interface of the next mount the client sends.
    func nextMount() async -> String? {
        if iterator == nil { iterator = mounts.makeAsyncIterator() }
        return await iterator?.next()
    }

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply { AppsListReply(revision: 1, apps: apps) }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        throw AppsTransportError(message: "unsupported", connectionLost: false)
    }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
        interfaces.append(interface)
        surfaces.append(context["surface"]?.stringValue ?? "")
        mountIDs.append(mountID)
        mounted.yield(interface)
    }
    func unmount(mountID: String) async throws(AppsTransportError) {}
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON { .null }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
}
