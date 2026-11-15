import AppKit
@testable import CmuxNextApps
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// An extension's web pane (`render: web`): its calls go only through the daemon's scoped page
/// bridge (`apps-page-call`), the daemon's refusals reach the page as errors, and a save of the
/// app's files reloads the open page.
@MainActor
struct AppWebPaneTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        /// (app, page, message) of each page call.
        var pageCalls: [(String, String, String)] = []
        /// The daemon's answer for an op.
        var answers: [String: AppJSON] = [:]

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply { AppsListReply(revision: 1, apps: []) }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {}
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON { .null }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
        func pageCall(app: String, page: String, message: String) async throws(AppsTransportError) -> AppJSON {
            pageCalls.append((app, page, message))
            let sent = (try? AppJSON.parse(message)) ?? .null
            let id = sent["id"] ?? .null
            return answers[sent["op"]?.stringValue ?? ""].map { answer in
                var answer = answer.objectValue ?? [:]
                answer["id"] = id
                return .object(answer)
            } ?? ["id": id, "ok": false, "error": ["code": "operation.unsupported", "message": "no answer"]]
        }
    }

    private static let manifest: AppJSON = [
        "id": "local/web-pane", "manifestVersion": 2, "version": "1.0.0", "name": "Web pane",
        "runtime": ["web": ["root": "web"]],
        "implements": ["cmux.pane/1": ["web": "web/index.html", "symbol": "globe"]],
    ]

    private static func record(package: URL?, entry: String = "index.html") -> AppRecord? {
        var json: [String: AppJSON] = [
            "id": "local/web-pane", "installed": true, "manifest": manifest,
            "web_pages": [["interface": "cmux.pane/1", "root": "web", "entry": .string(entry), "symbol": "globe"]],
        ]
        if let package { json["bundle_dir"] = .string(package.path) }
        return AppRecord(json: .object(json))
    }

    private static func provider(_ transport: Transport) -> AppWebPaneProvider {
        AppWebPaneProvider(appID: "local/web-pane", pageKey: "p1", prefix: "local.web-pane.") { message async throws(AppsTransportError) -> AppJSON in
            try await transport.pageCall(app: "local/web-pane", page: "p1", message: message)
        }
    }

    @Test func theRecordNamesItsWebPaneAndOpensAsItsOwnPage() throws {
        let record = try #require(Self.record(package: URL(fileURLWithPath: "/tmp/pkg")))
        #expect(record.webPane == AppWebPage(interface: "cmux.pane/1", root: "web", entry: "index.html", symbol: "globe"))
        #expect(record.manifest.scenePane == nil)
        #expect(AppOpenTarget(record) == .scenePane)
    }

    @Test func aRootThatLeavesThePackageIsRefused() {
        let package = URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)
        #expect(AppWebPage(interface: "cmux.pane/1", root: "web", entry: "index.html").rootURL(in: package)?.lastPathComponent == "web")
        for root in ["../web", "/etc", "web/../..", "./web", "a\\b"] {
            #expect(AppWebPage(interface: "cmux.pane/1", root: root, entry: "index.html").rootURL(in: package) == nil, "\(root)")
        }
    }

    /// A root that is a symlink out of the package (`web` -> `/etc`) is refused, as the daemon's
    /// `resolve_request` refuses it; a root linked to a folder inside the package still serves.
    @Test func aRootLinkedOutOfThePackageIsRefused() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("web-pane-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("site"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("web").path, withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("inside").path, withDestinationPath: "site")
        #expect(AppWebPage(interface: "cmux.pane/1", root: "web", entry: "index.html").rootURL(in: package) == nil)
        #expect(AppWebPage(interface: "cmux.pane/1", root: "inside", entry: "index.html").rootURL(in: package)?.lastPathComponent == "site")
    }

    /// The page's `<host>.<op>` reaches the daemon as the app's own op, unparsed and with this
    /// page's key; the daemon's value comes back.
    @Test func aCallGoesToTheDaemonAsTheAppsOp() async throws {
        let transport = Transport()
        transport.answers["workspace.list"] = ["ok": true, "value": ["workspaces": []]]
        let value = try await Self.provider(transport).call("local.web-pane.workspace.list", params: ["all": true],
                                                             context: PageCallContext(page: "local.web-pane"))
        #expect(value == ["workspaces": []])
        let (app, page, message) = try #require(transport.pageCalls.first)
        #expect(app == "local/web-pane" && page == "p1")
        let sent = try AppJSON.parse(message)
        #expect(sent["op"] == "workspace.list")
        #expect(sent["params"] == ["all": true])
    }

    /// next-review's BLOCK at b2afa11 (P1-F1, blocks:security): a page's call with a 17 MiB param
    /// made a control request over the socket's 16 MiB line limit, which closed the app's shared
    /// daemon connection before the daemon's own 256 KiB bridge check ran. A message over the
    /// bridge limit is refused here, before it is sent; one at the limit still goes.
    @Test func anOversizedPageMessageNeverReachesTheDaemon() async throws {
        let transport = Transport()
        transport.answers["workspace.list"] = ["ok": true, "value": ["workspaces": []]]
        let provider = Self.provider(transport)
        let huge = String(repeating: "x", count: 17 * 1024 * 1024)
        do {
            _ = try await provider.call("local.web-pane.workspace.list", params: ["pad": .string(huge)],
                                        context: PageCallContext(page: "local.web-pane"))
            Issue.record("an oversized message was sent")
        } catch let error as PageError {
            #expect(error.code == "bridge.message_too_large")
        }
        let over = String(repeating: "y", count: 256 * 1024)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("local.web-pane.workspace.list", params: ["pad": .string(over)],
                                        context: PageCallContext(page: "local.web-pane"))
        }
        #expect(transport.pageCalls.isEmpty)
        _ = try await provider.call("local.web-pane.workspace.list", params: ["pad": .string(String(repeating: "z", count: 1024))],
                                    context: PageCallContext(page: "local.web-pane"))
        #expect(transport.pageCalls.count == 1)
    }

    /// A call outside the app's scopes is refused by the daemon, and the page gets that refusal
    /// as its call's error; nothing on this side lets it through.
    @Test func theDaemonsRefusalReachesThePage() async throws {
        let transport = Transport()
        transport.answers["workspace.rename"] = ["ok": false, "error": ["code": "scope.missing", "message": "workspace:write is not granted"]]
        do {
            _ = try await Self.provider(transport).call("local.web-pane.workspace.rename", params: [:],
                                                         context: PageCallContext(page: "local.web-pane"))
            Issue.record("a refused call returned a value")
        } catch let error as PageError {
            #expect(error.code == "scope.missing")
        }
    }

    /// An op outside the page's own namespace never leaves the host.
    @Test func anOpOutsideThePagesNamespaceIsUnknown() async throws {
        let transport = Transport()
        await #expect(throws: PageError.self) {
            _ = try await Self.provider(transport).call("cmux.settings.get", params: [:], context: PageCallContext(page: "local.web-pane"))
        }
        #expect(transport.pageCalls.isEmpty)
    }

    /// `apps-changed` from a local reload names its app; the open web page of that app reloads,
    /// another app's save leaves it alone.
    @Test func aSaveOfTheAppsFilesReloadsItsOpenPage() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("web-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("web"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try Data("<!doctype html><p>hi</p>".utf8).write(to: package.appendingPathComponent("web/index.html"))
        let transport = Transport()
        let client = AppsClient(transport: transport)
        let views = AppPaneViews(client: client)
        let record = try #require(Self.record(package: package))
        let view = views.makeView(record, key: "tab-1")
        #expect(view is PageWebView)
        #expect(views.webPage("tab-1")?.pageID == "local.web-pane")
        #expect(views.webPageReloads("tab-1") == 0)
        transport.onEvent?(.changed(revision: 1, app: "local/other"))
        transport.onEvent?(.changed(revision: 1))
        #expect(views.webPageReloads("tab-1") == 0)
        transport.onEvent?(.changed(revision: 1, app: "local/web-pane"))
        #expect(views.webPageReloads("tab-1") == 1)
        views.close("tab-1")
        #expect(views.webPage("tab-1") == nil)
    }

    /// next-review's BLOCK on #43033 (P1, blocks:security): the extension pane's own router refuses
    /// the host ops the shared PageRouter answers itself (a raw title bar double-click zoomed or
    /// minimized cmux with no grant or gesture), runs none of them and sends nothing to the daemon.
    @Test func theExtensionPaneRunsNoHostOpOutsideItsNamespace() async throws {
        let package = try Self.package(entry: "index.html")
        defer { try? FileManager.default.removeItem(at: package) }
        let transport = Transport()
        let views = AppPaneViews(client: AppsClient(transport: transport))
        _ = views.makeView(try #require(Self.record(package: package)), key: "tab-1")
        defer { views.close("tab-1") }
        let router = try #require(views.webPage("tab-1")).router
        var ran: [String] = []
        router.titleBarDoubleClick = { ran.append("title_bar_double_click") }
        router.contextMenu = { _ in ran.append("contextMenu"); return ["picked": .null] }
        router.historyNavigate = { _, _ in ran.append("history"); return true }
        let calls: [(op: String, params: CmuxNextSettings.JSONValue)] = [
            (PageNativeOp.titleBarDoubleClick, .object([:])),
            (PageNativeOp.contextMenu, .object(["items": .array([])])),
            (PageNativeOp.historyNavigate, .object(["back": .bool(true), "g": .number(1)])),
        ]
        for (index, (op, params)) in calls.enumerated() {
            let message: CmuxNextSettings.JSONValue = .object([
                "t": .string("call"), "id": .number(Double(index + 1)), "op": .string(op), "params": params,
            ])
            let reply = await router.handle(message)
            #expect(reply["code"]?.stringValue == "cmux.protocol.unknown_op", "\(op) answered \(reply)")
        }
        #expect(ran.isEmpty)
        #expect(transport.pageCalls.isEmpty)
    }

    /// A package with `web/<entry>` in a fresh temporary folder.
    private static func package(entry: String) throws -> URL {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("web-pane-\(UUID().uuidString)", isDirectory: true)
        let file = package.appendingPathComponent("web").appendingPathComponent(entry)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<!doctype html><p>hi</p>".utf8).write(to: file)
        return package
    }

    /// An extension's page never leaves its origin. A link it activates to another origin is
    /// cancelled and opened nowhere: routed through LinkRouter, its URL would carry what the page
    /// put in it (workspace data in a query) past the page bridge, the grant and egress checks.
    /// Base red: the host had no navigation hook, so the link went to `.openExternal` (LinkRouter).
    @Test func anExternalLinkFromTheExtensionPageIsRefused() async throws {
        let package = try Self.package(entry: "index.html")
        defer { try? FileManager.default.removeItem(at: package) }
        let views = AppPaneViews(client: AppsClient(transport: Transport()))
        _ = views.makeView(try #require(Self.record(package: package)), key: "tab-1")
        let page = try #require(views.webPage("tab-1"))
        defer { views.close("tab-1") }
        // Whatever would go to LinkRouter goes here instead (``PageWebView/onOpenExternal``).
        var opened: [URL] = []
        page.onOpenExternal = { opened.append($0) }
        let webView = WKWebView()

        #expect(await page.webView(webView, decidePolicyFor: FakeNavigationAction(url: page.descriptor.url())) == .allow)
        let leak = try #require(URL(string: "https://attacker.example/collect?workspaces=secret"))
        #expect(await page.webView(webView, decidePolicyFor: FakeNavigationAction(url: leak, type: .linkActivated)) == .cancel)
        #expect(await page.webView(webView, decidePolicyFor: FakeNavigationAction(url: leak, type: .formSubmitted)) == .cancel)
        #expect(await page.webView(webView, decidePolicyFor: FakeNavigationAction(url: leak)) == .cancel)
        let mail = try #require(URL(string: "mailto:someone@example.com?body=secret"))
        #expect(await page.webView(webView, decidePolicyFor: FakeNavigationAction(url: mail, type: .linkActivated)) == .cancel)
        let other = try #require(URL(string: "cmux-page://local.other/"))
        #expect(await page.webView(webView, decidePolicyFor: FakeNavigationAction(url: other, type: .linkActivated)) == .cancel)
        #expect(opened.isEmpty, "a link left the extension page: \(opened)")
    }

    /// The daemon's entry may be nested in the root (`ui/index.html`, valid per the manifest): the
    /// page loads that file at its own path. Base red: the entry fell back to `index.html`.
    @Test func aNestedEntryIsThePagesDocument() throws {
        let package = try Self.package(entry: "ui/index.html")
        defer { try? FileManager.default.removeItem(at: package) }
        let views = AppPaneViews(client: AppsClient(transport: Transport()))
        _ = views.makeView(try #require(Self.record(package: package, entry: "ui/index.html")), key: "tab-1")
        let page = try #require(views.webPage("tab-1"))
        defer { views.close("tab-1") }
        #expect(page.descriptor.entry == "ui/index.html")
        #expect(page.descriptor.url().absoluteString == "cmux-page://local.web-pane/ui/index.html")
    }

    @Test func aLocalReloadEventNamesItsApp() {
        typealias Wire = CmuxNextDaemon.JSONValue
        let decode = AppsWireDecoding()
        let reload: Wire = .object(["revision": .number(3), "transaction": .string("local-reload"), "app": .string("local/web-pane")])
        #expect(decode.event(name: "apps-changed", payload: reload) == .changed(revision: 3, app: "local/web-pane"))
        let other: Wire = .object(["revision": .number(4), "app": .string("local/web-pane")])
        #expect(decode.event(name: "apps-changed", payload: other) == .changed(revision: 4))
    }
}
