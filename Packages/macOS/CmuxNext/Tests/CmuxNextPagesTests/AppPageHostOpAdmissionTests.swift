import Foundation
import CmuxNextSettings
@testable import CmuxNextPages
import Testing
import WebKit

/// next-review's BLOCK on #43033 (P1, blocks:security): an extension's web page went through the
/// generic ``PageRouter``, whose built-in host ops ran before namespace admission, so a page could
/// post a raw `cmux.app.window.title_bar_double_click` and zoom or minimize cmux with no grant or
/// gesture. An app page (``PageDescriptor/appPage(id:resource:namespaces:entry:)``) admits only its
/// own `<host>.` ops: every message it sends passes that admission before anything runs, the
/// router's own host ops and streams included. A first-party page keeps them.
@MainActor @Suite
struct AppPageHostOpAdmissionTests {
    /// Every op the router answers itself, with params that would run it on a page that may.
    static let hostOps: [(op: String, params: JSONValue)] = [
        (PageNativeOp.titleBarDoubleClick, [:]),
        (PageNativeOp.historyNavigate, ["back": true, "g": 1]),
        (PageNativeOp.swipeRelease, ["g": 1]),
        (PageNativeOp.pageHeartbeat, ["handled": 1]),
        (PageNativeOp.popupShow, ["id": "p", "x": 0, "y": 0]),
        (PageNativeOp.popupUpdate, ["id": "p"]),
        (PageNativeOp.popupHide, [:]),
        (PageNativeOp.contextMenu, ["items": []]),
    ]

    /// What the host ran for a router's page.
    final class Ran {
        var ops: [String] = []
    }

    static func wire(_ router: PageRouter, _ ran: Ran) {
        router.titleBarDoubleClick = { ran.ops.append(PageNativeOp.titleBarDoubleClick) }
        router.historyNavigate = { _, _ in ran.ops.append(PageNativeOp.historyNavigate); return true }
        router.swipeRelease = { _ in ran.ops.append(PageNativeOp.swipeRelease) }
        router.heartbeat = { _, _, _ in ran.ops.append(PageNativeOp.pageHeartbeat); return true }
        router.popup = { op, _ in ran.ops.append(op); return ["shown": true] }
        router.contextMenu = { _ in ran.ops.append(PageNativeOp.contextMenu); return ["picked": .null] }
    }

    @Test func anExtensionPageReachesNoHostOpItsNamespaceDoesNotAdmit() async throws {
        let descriptor = try PageDescriptor.appPage(id: "com.example.ext", resource: "ui", namespaces: ["com.example.ext."])
        let router = PageRouter(descriptor: descriptor, routes: [])
        let ran = Ran()
        Self.wire(router, ran)
        var id = 0
        for (op, params) in Self.hostOps {
            id += 1
            let reply = await router.handle(["t": "call", "id": .number(Double(id)), "op": .string(op), "params": params])
            #expect(reply["t"]?.stringValue == "err", "\(op) answered \(reply)")
            #expect(reply["code"]?.stringValue == "cmux.protocol.unknown_op", "\(op) answered \(reply)")
        }
        #expect(ran.ops.isEmpty, "the host ran \(ran.ops) for an extension page")
        // Nor does it subscribe to the router's own streams (commands, connection, popups, swipes).
        for stream in PageNativeOp.builtInStreams.sorted() {
            id += 1
            let reply = await router.handle(["t": "sub", "id": .number(Double(id)), "stream": .string(stream)])
            #expect(reply["code"]?.stringValue == "cmux.protocol.unknown_op", "\(stream) answered \(reply)")
        }
        #expect(router.builtIn.isEmpty)
        #expect(!router.hasSwipeSubscriber)
    }

    /// next-review's BLOCK at 0162166 (P1-F1): the title row press is a host op outside the router
    /// (`cmuxTitleRowPress`, a page script's report that moves, zooms or minimizes the window). An
    /// extension page fabricating one from its own click handler passed the gesture check, so an app
    /// page gets neither its script nor its handler; another page keeps both.
    @Test func anExtensionPageGetsNoTitleRowPress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Ext</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let marker = "__cmuxTitleRowPress"
        let app = try PageDescriptor.appPage(id: "com.example.ext", resource: "ext", namespaces: ["com.example.ext."])
        let extensionPage = try #require(PageWebView(descriptor: app, root: root, testRoot: true, routes: [], route: "#/"))
        defer { extensionPage.close() }
        #expect(!extensionPage.webView.configuration.userContentController.userScripts.contains { $0.source.contains(marker) })
        let other = PageDescriptor(id: "test.title-row", resource: "title-row", namespaces: [])
        let page = try #require(PageWebView(descriptor: other, root: root, testRoot: true, routes: [], route: "#/"))
        defer { page.close() }
        #expect(page.webView.configuration.userContentController.userScripts.contains { $0.source.contains(marker) })
    }

    @Test func aFirstPartyPageStillRunsTheRoutersHostOps() async {
        let descriptor = PageDescriptor(id: "cmux.host-op-test", resource: "host-op-test", namespaces: ["cmux.host-op-test."])
        let router = PageRouter(descriptor: descriptor, routes: [])
        let ran = Ran()
        Self.wire(router, ran)
        var id = 0
        for (op, params) in Self.hostOps {
            id += 1
            let reply = await router.handle(["t": "call", "id": .number(Double(id)), "op": .string(op), "params": params])
            #expect(reply["t"]?.stringValue == "ok", "\(op) answered \(reply)")
        }
        #expect(ran.ops == Self.hostOps.map(\.op))
        id += 1
        let sub = await router.handle(["t": "sub", "id": .number(Double(id)), "stream": .string(PageNativeOp.pageSwipe)])
        #expect(sub["t"]?.stringValue == "ok", "\(sub)")
        #expect(router.hasSwipeSubscriber)
    }
}
