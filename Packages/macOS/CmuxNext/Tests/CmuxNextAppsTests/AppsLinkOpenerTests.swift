@testable import CmuxNextApps
import Foundation
import Testing

/// A clicked link goes first to the app whose `cmux.opener/1` matches it (the daemon picks the
/// app, `apps-open-link`). The client asks only while a visible app implements an opener, and
/// the list an `apps-changed` brings back decides that: a saved manifest that adds or drops the
/// opener changes the next click with no relaunch.
@MainActor @Suite(.serialized) struct AppsLinkOpenerTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var revision: UInt64 = 1
        var implementsOpener = true
        var hidden = false
        var offered: [String] = []

        private var manifest: AppJSON {
            var implements: [String: AppJSON] = ["cmux.section/1": ["export": "render", "title": "Jira"]]
            if implementsOpener {
                implements["cmux.opener/1"] = ["export": "openLink", "options": ["urls": ["https://jira.example/browse/*"]]]
            }
            return ["manifestVersion": 2, "id": "local/jira", "name": "Jira", "version": .string("1.0.\(revision)"), "implements": .object(implements)]
        }

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            let record = AppRecord(json: ["id": "local/jira", "installed": true, "hidden": .bool(hidden), "manifest": manifest])
            return AppsListReply(revision: revision, apps: [record].compactMap { $0 })
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {}
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
        func openLink(_ url: String, origin: AppOrigin) async throws(AppsTransportError) -> AppJSON {
            offered.append(url)
            return url.contains("jira.example") ? ["handled": true, "app": "local/jira"] : ["handled": false]
        }
    }

    private static func started(_ transport: Transport) async -> AppsClient {
        let client = AppsClient(transport: transport)
        client.start()
        for _ in 0..<100 where !client.hasList { await Task.yield() }
        return client
    }

    /// Lets the list a `changed` event asked for land.
    private static func changed(_ transport: Transport, _ client: AppsClient) async {
        transport.revision += 1
        transport.onEvent?(.changed(revision: transport.revision))
        for _ in 0..<100 { await Task.yield() }
    }

    private let jira = URL(string: "https://jira.example/browse/ABC-1") ?? URL(fileURLWithPath: "/")

    @Test func aMatchingLinkGoesToTheOpenerAndOthersStayWithCmux() async {
        let transport = Transport()
        let client = await Self.started(transport)
        #expect(client.hasLinkOpeners)
        #expect(await client.openLink(jira) == "local/jira")
        #expect(await client.openLink(URL(string: "https://news.example/") ?? URL(fileURLWithPath: "/")) == nil)
        #expect(transport.offered == [jira.absoluteString, "https://news.example/"])
    }

    @Test func aSavedManifestThatDropsTheOpenerStopsAskingWithNoRelaunch() async {
        let transport = Transport()
        let client = await Self.started(transport)
        transport.implementsOpener = false
        await Self.changed(transport, client)
        #expect(!client.hasLinkOpeners)
        #expect(await client.openLink(jira) == nil)
        #expect(transport.offered.isEmpty, "no round trip while no app opens links")
        transport.implementsOpener = true
        await Self.changed(transport, client)
        #expect(await client.openLink(jira) == "local/jira")
    }

    @Test func aHiddenAppOpensNothing() async {
        let transport = Transport()
        transport.hidden = true
        let client = await Self.started(transport)
        #expect(!client.hasLinkOpeners)
        #expect(await client.openLink(jira) == nil)
        #expect(transport.offered.isEmpty)
    }
}
