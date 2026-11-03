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
            "app": "local/customize", "section": "prs",
            "context": .object(["session_id": "s1", "cwd": "/tmp/repo", "branch": "main"]),
        ]), context: Self.page)
        let mountID = try #require(mounted["mount_id"]?.stringValue)
        await client.tail?.value
        let sent = try #require(transport.mounts.first)
        #expect(sent.interface == "cmux.session.info.section/1")
        #expect(sent.context["session_id"]?.stringValue == "s1")
        #expect(sent.context["cwd"]?.stringValue == "/tmp/repo")
        #expect(sent.context["surface"]?.stringValue == "sessionInfoSection")

        // Ops that land before the page subscribes reach its first subscriber as a reset.
        transport.onEvent?(.scene(mountID: mountID, ops: [.root(id: "n1")]))
        let box = Heard()
        let subscription = try await provider.subscribe("cmux.apps.panels.scene", filter: .object(["mount_id": .string(mountID)]),
                                                        context: Self.page) { box.events.append($0) }
        #expect(box.events.count == 1)
        #expect(box.events.first?["reset"]?.boolValue == true)
        #expect(box.events.first?["ops"]?.arrayValue?.first?["op"]?.stringValue == "root")
        transport.onEvent?(.scene(mountID: mountID, ops: [.remove(id: "n1")]))
        #expect(box.events.count == 2)
        #expect(box.events.last?["reset"] == nil)
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
}

@MainActor
private final class Heard {
    var events: [JSONValue] = []
}

@MainActor
private final class FakePanelsTransport: AppsTransport {
    var availability: AppsAvailability = .available(epoch: 1)
    var onEvent: ((AppsTransportEvent) -> Void)?
    var mounts: [(interface: String, context: AppJSON)] = []
    var unmounts: [String] = []
    var dispatches: [String] = []

    private static let manifest: AppJSON = [
        "id": "local/customize", "version": "1.0.0", "publisher": ["name": "local"],
        "contributes": ["sessionInfoSections": [["id": "prs", "title": "PRs", "render": "renderPRs"]]],
    ]

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply {
        AppsListReply(revision: 1, apps: [AppRecord(json: ["id": "local/customize", "installed": true, "manifest": Self.manifest])].compactMap { $0 })
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
