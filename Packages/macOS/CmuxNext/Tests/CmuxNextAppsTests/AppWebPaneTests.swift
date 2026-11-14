import AppKit
@testable import CmuxNextApps
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

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

    private static func record(package: URL?) -> AppRecord? {
        var json: [String: AppJSON] = [
            "id": "local/web-pane", "installed": true, "manifest": manifest,
            "web_pages": [["interface": "cmux.pane/1", "root": "web", "entry": "index.html", "symbol": "globe"]],
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

    @Test func aLocalReloadEventNamesItsApp() {
        typealias Wire = CmuxNextDaemon.JSONValue
        let decode = AppsWireDecoding()
        let reload: Wire = .object(["revision": .number(3), "transaction": .string("local-reload"), "app": .string("local/web-pane")])
        #expect(decode.event(name: "apps-changed", payload: reload) == .changed(revision: 3, app: "local/web-pane"))
        let other: Wire = .object(["revision": .number(4), "app": .string("local/web-pane")])
        #expect(decode.event(name: "apps-changed", payload: other) == .changed(revision: 4))
    }
}
