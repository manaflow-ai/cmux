import AppKit
@testable import CmuxNextApps
import CmuxNextCompat
import Testing
import WebKit

/// A registry replacement can change both the web root and the entry document.
@MainActor
struct AppWebPaneUpdateTests {
    @Test(.timeLimit(.minutes(1))) func anOpenPaneFollowsTheReplacedManifest() async throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("pane-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let oldRoot = bundle.appendingPathComponent("web")
        let newRoot = bundle.appendingPathComponent("ui")
        try writePage(root: oldRoot, entry: "index.html", version: "one")
        let first = try record(bundle: bundle, root: "web", entry: "index.html", version: "1.0.0", csp: "img-src 'self'")
        let transport = UpdatingPaneTransport(record: first)
        let client = AppsClient(transport: transport)
        client.start()
        await waitForVersion("1.0.0", client: client, app: first.id)
        let pane = try #require(AppWebPane(manifest: first.manifest, bundle: bundle))
        let view = AppWebPaneView(pane: pane, client: client)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        await transport.waitForLog("ready one")

        try writePage(root: newRoot, entry: "main.html", version: "two")
        try FileManager.default.removeItem(at: oldRoot)
        transport.record = try record(bundle: bundle, root: "ui", entry: "main.html", version: "2.0.0")
        // No task has delivered the new catalog yet. A file notification must not reload
        // v2 files under the old manifest/root/policy while that list is in flight.
        transport.onEvent?(.changed(revision: 2, app: first.id, transaction: "registry-put"))
        #expect(client.fileRevisions[first.id, default: 0] == 0)
        await waitForVersion("2.0.0", client: client, app: first.id)
        await transport.waitForLog("ready two")
        #expect(view.pane.entryURL.absoluteString == "cmux-app://local.board/main.html")
        #expect(view.hotReloads == 1)
        let title = try await view.webView.evaluateJavaScript("document.title") as? String
        #expect(title == "two")
        let policy = try await view.webView.callAsyncJavaScript(
            "return (await fetch('main.html')).headers.get('Content-Security-Policy')", arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(policy == AppWebPane.hostCSP + ", img-src 'none'")

        // An approved version can also remove its web implementation. It must
        // discard the old document and revoke its bridge, rather than leave it live.
        var noPane = transport.record
        noPane.version = "3.0.0"
        noPane.manifest = try #require(AppManifest(json: [
            "manifestVersion": 2, "id": "local/board", "name": "Board", "version": "3.0.0",
            "runtime": ["web": ["root": "ui/"]], "implements": [:],
        ]))
        let (loaded, didLoad) = AsyncStream.makeStream(of: Void.self)
        view.onLoaded = { didLoad.yield() }
        transport.record = noPane
        transport.onEvent?(.changed(revision: 3, app: first.id, transaction: "registry-put"))
        await waitForVersion("3.0.0", client: client, app: first.id)
        for await _ in loaded { break }
        #expect(view.webView.url?.absoluteString == "about:blank")
        #expect(!view.bridge.enabled)
        let cleared = try await view.webView.evaluateJavaScript("document.title") as? String
        #expect(cleared == "")
        let refused = try await view.webView.callAsyncJavaScript(
            "try { await cmux.call('workspace.list', {}); return 'ran' } catch (e) { return e.code }",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(refused == "bridge.origin")
    }

    private func writePage(root: URL, entry: String, version: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<!doctype html><title>\(version)</title><script src='app.js'></script>".write(to: root.appendingPathComponent(entry), atomically: true, encoding: .utf8)
        try "console.info('ready \(version)');".write(to: root.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
    }

    private func record(bundle: URL, root: String, entry: String, version: String, csp: String = "img-src 'none'") throws -> AppRecord {
        let manifest = try #require(AppManifest(json: [
            "manifestVersion": 2, "id": "local/board", "name": "Board", "version": .string(version),
            "runtime": ["web": ["root": .string(root + "/"), "csp": .string(csp)]],
            "implements": ["cmux.pane/1": ["web": .string(root + "/" + entry), "title": "Board"]],
        ]))
        var record = AppRecord(manifest: manifest, tier: .unverified, installed: true, source: .registry)
        record.bundleDirectory = bundle
        return record
    }

    private func waitForVersion(_ version: String, client: AppsClient, app: String) async {
        let (first, later) = ObservationStream.current { client.app(app)?.version }
        if first == version { return }
        for await next in later where next == version { return }
    }
}

/// The supervisor's successive catalog snapshots and the real web pane's console.
@MainActor
private final class UpdatingPaneTransport: AppsTransport {
    let availability: AppsAvailability = .available(epoch: 1)
    var onEvent: ((AppsTransportEvent) -> Void)?
    var record: AppRecord
    private var messages: [String] = []
    private let (lines, line) = AsyncStream.makeStream(of: String.self)

    init(record: AppRecord) { self.record = record }
    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply { AppsListReply(revision: nil, apps: [record]) }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord { record }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {}
    func unmount(mountID: String) async throws(AppsTransportError) {}
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON { [:] }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    func webCall(app: String, op: String, args: AppJSON) async throws(AppsTransportError) -> AppJSON { [:] }
    func registryPut(app: String, version: String, sha256: String, files: [String: String]) async throws(AppsTransportError) {}
    func webLog(app: String, level: String, message: String) async throws(AppsTransportError) {
        messages.append(message)
        line.yield(message)
    }

    func waitForLog(_ text: String) async {
        if messages.contains(text) { return }
        for await message in lines where message == text { return }
    }
}
