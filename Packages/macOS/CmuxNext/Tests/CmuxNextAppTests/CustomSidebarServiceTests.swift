@testable import CmuxNextApps
import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Observation
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
        #expect(service.customSidebarKey == nil)
        #expect(service.makeCustomSidebar() == nil)
        #expect(transport.interfaces == ["cmux.sidebar.rows/1"], "no custom sidebar mount: \(transport.interfaces)")
    }

    @Test func aScriptReplacesTheListWithOneMount() async throws {
        let transport = CustomSidebarTransport(apps: [try Self.record(implements: ["cmux.sidebar/1": "sidebar"])])
        let client = await Self.listed(transport)
        let service = SidebarCustomizationService(client: client) { _ in true }
        #expect(service.customSidebarKey == "local/customize#cmux.sidebar/1@1.0.0")
        #expect(transport.interfaces.isEmpty, "nothing mounts until a window's sidebar asks")
        let content = try #require(service.makeCustomSidebar())
        defer { content.release() }
        let first = await transport.nextMount()
        #expect(first == "cmux.sidebar/1")
        #expect(transport.surfaces == ["customSidebar"])
        // The first scene arrives: the content is ready and shows the script's view.
        let mountID = try #require(transport.mountIDs.first)
        transport.onEvent?(.scene(mountID: mountID, ops: [.create(id: "t", type: "Text", props: ["text": "hi"]), .root(id: "t")]))
        #expect(content.isReady)
        #expect(content.errorText == nil)
    }
}

/// An app supervisor that lists `apps` and records mounts.
@Observable
final class CustomSidebarTransport: AppsTransport {
    @ObservationIgnored let apps: [AppRecord]
    var availability: AppsAvailability { .available(epoch: 1) }
    @ObservationIgnored var onEvent: ((AppsTransportEvent) -> Void)?
    private(set) var interfaces: [String] = []
    @ObservationIgnored private(set) var surfaces: [String] = []
    @ObservationIgnored private(set) var mountIDs: [String] = []
    @ObservationIgnored private var taken = 0

    init(apps: [AppRecord]) { self.apps = apps }

    /// The interface of the next mount the client sends.
    func nextMount() async -> String? {
        for await count in ObservationStream({ self.interfaces.count }) where count > taken { break }
        taken += 1
        return interfaces[taken - 1]
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
    }
    func unmount(mountID: String) async throws(AppsTransportError) {}
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON { .null }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
}
