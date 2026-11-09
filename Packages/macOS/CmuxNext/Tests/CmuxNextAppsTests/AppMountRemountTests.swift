@testable import CmuxNextApps
import Testing

/// A local app's folder re-saved (the customize app's `main.js` or `cmux-app.json`): the supervisor
/// removes the app and adds it back, failing its live mounts with "removed" in between. A sidebar
/// section that shows the app mounts again once the list has the app back, so it draws the new
/// script instead of a stale "removed" row; a mount whose app stays gone is left failed.
@MainActor @Suite(.serialized) struct AppMountRemountTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var listed = true
        var revision: UInt64 = 1
        var mounted: [String] = []

        private static let manifest: AppJSON = [
            "id": "local/customize", "version": "1.0.0", "publisher": ["name": "local"],
            "contributes": ["sidebarSections": [["id": "main", "title": "My section", "render": "renderSection"]]],
        ]

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            let apps = listed ? [AppRecord(json: ["id": "local/customize", "installed": true, "manifest": Self.manifest])].compactMap { $0 } : []
            return AppsListReply(revision: revision, apps: apps)
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
            mounted.append(mountID)
        }
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    /// A started client with the app listed, and a mounted sidebar section of it that the supervisor
    /// then failed with "removed".
    private static func removedMount() async throws -> (Transport, AppsClient, AppMount) {
        let transport = Transport()
        let client = AppsClient(transport: transport)
        client.start()
        for _ in 0..<100 where !client.hasList { await Task.yield() }
        let section = try #require(client.app("local/customize")?.manifest.sections.first)
        let mount = client.mount("local/customize", implementation: section, surface: "sidebarSection")
        await client.tail?.value
        #expect(transport.mounted == [mount.id])
        transport.onEvent?(.mountFailed(mountID: mount.id, reason: "removed"))
        #expect(mount.model.status == .failed("removed"))
        return (transport, client, mount)
    }

    /// Lets the list the `changed` event asked for land, and any mount it sends.
    private static func settle(_ client: AppsClient) async {
        for _ in 0..<100 {
            await Task.yield()
            await client.tail?.value
        }
    }

    @Test func aMountFailedAsRemovedMountsAgainWhenItsAppIsListedAgain() async throws {
        let (transport, client, mount) = try await Self.removedMount()
        transport.revision = 2
        transport.onEvent?(.changed(revision: 2))
        await Self.settle(client)
        #expect(transport.mounted == [mount.id, mount.id], "the section's mount is sent again")
        #expect(mount.model.status == .loading, "the stale failure is gone while the new script renders")
    }

    @Test func aMountWhoseAppStaysGoneStaysFailed() async throws {
        let (transport, client, mount) = try await Self.removedMount()
        transport.listed = false
        transport.revision = 2
        transport.onEvent?(.changed(revision: 2))
        await Self.settle(client)
        #expect(transport.mounted == [mount.id])
        #expect(mount.model.status == .failed("removed"))
    }
}
