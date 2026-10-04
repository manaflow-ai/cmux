import AppKit
import CmuxNextSettings
import Foundation
import Testing
import WebKit
@testable import CmuxNextPages

/// DESKTOP-FEEL (R139): every PageWebView has the host half of the desktop layer. No
/// magnification, no swipe navigation, no link previews, the context menu keeps only Copy, Select
/// All acts only in the focused field, and a drawn title bar's double-click reaches the window
/// action through the built-in op.
@MainActor
@Suite struct PageDesktopDefaultsTests {
    private static let page = PageDescriptor(id: "com.example.desktop", resource: "desktop", namespaces: ["com.example.desktop."])

    private static func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "page-desktop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<!doctype html><title>t</title>".utf8).write(to: dir.appending(path: "index.html"))
        return dir
    }

    @Test func everyPageViewHasTheDesktopDefaults() throws {
        let view = try #require(PageWebView(descriptor: Self.page, root: try Self.root(), routes: []))
        let web = view.webKitView
        #expect(web is PageWKWebView, "pages use the desktop WebKit view")
        #expect(web.allowsMagnification == false)
        #expect(web.allowsBackForwardNavigationGestures == false)
        #expect(web.allowsLinkPreview == false)
    }

    @Test func theContextMenuKeepsOnlyCopy() {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierInspectElement", "WKMenuItemIdentifierLookUp"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        PageWKWebView.keepDesktopItems(in: menu)
        #expect(menu.items.map { $0.identifier?.rawValue } == ["WKMenuItemIdentifierCopy"])
    }

    @Test func aTitleBarDoubleClickRunsTheHostActionForAnyPage() async {
        let router = PageRouter(descriptor: Self.page, routes: [])
        var runs = 0
        router.titleBarDoubleClick = { runs += 1 }
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.titleBarDoubleClick), "params": [:]])
        #expect(reply["t"] == "ok", "built in: no descriptor lists it")
        #expect(runs == 1)
    }
}
