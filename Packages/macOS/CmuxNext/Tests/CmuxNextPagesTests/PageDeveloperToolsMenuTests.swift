import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Every cmux page's right-click menu ends with Inspect Element while developer tools for cmux
/// pages are on (`developerTools.appPages`), in WebKit and in Chromium (the agent chat's default
/// engine), and choosing it inspects that page (Lawrence, 2026-11-07: "make it possible to open
/// chrome devtools in chat ui itself").
@MainActor
struct PageDeveloperToolsMenuTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.devtools-menu", resource: "devtools-menu", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-devtools-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private final class Recorder {
        var on = true
        var inspected: [NSView] = []
        var tools: PageDeveloperTools {
            PageDeveloperTools(isEnabled: { [unowned self] in on }, inspect: { [unowned self] in inspected.append($0) })
        }
    }

    @Test func appendAddsOneRowAfterASeparatorAndReplacesWebKitsItem() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let view = NSView()
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        let webKit = NSMenuItem(title: "Inspect Element", action: nil, keyEquivalent: "")
        webKit.identifier = NSUserInterfaceItemIdentifier(PageDeveloperTools.webKitItem)
        menu.addItem(webKit)
        recorder.tools.append(to: menu, for: view)
        recorder.tools.append(to: menu, for: view)
        #expect(menu.items.map(\.title) == ["Copy", "", PageDeveloperTools.title])
        #expect(menu.items[1].isSeparatorItem)
        let row = try #require(menu.items.last)
        #expect(row.identifier == PageDeveloperTools.itemIdentifier)
        _ = (row.target as? NSObject)?.perform(row.action)
        #expect(recorder.inspected.count == 1 && recorder.inspected.first === view)
    }

    @Test func offAddsNothingButStillDropsWebKitsItem() {
        _ = NSApplication.shared
        let recorder = Recorder()
        recorder.on = false
        let menu = NSMenu()
        let webKit = NSMenuItem(title: "Inspect Element", action: nil, keyEquivalent: "")
        webKit.identifier = NSUserInterfaceItemIdentifier(PageDeveloperTools.webKitItem)
        menu.addItem(webKit)
        recorder.tools.append(to: menu, for: NSView())
        #expect(menu.items.isEmpty)
    }

    /// A Chromium page's menu (built by the host, Chromium shows none) ends with Inspect Element,
    /// even with nothing selected, and a page that refuses probes offers none.
    @Test func aChromiumPageMenuOffersInspectElement() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        defer { view.close() }
        let recorder = Recorder()
        view.developerTools = recorder.tools
        var shown: NSMenu?
        view.chromiumMenuPresenter = { menu, _, _ in shown = menu }
        var finished = 0
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "", isEditable: false) { finished += 1 }))
        await PageMenuCallout.drain { shown != nil }
        let menu = try #require(shown)
        #expect(menu.items.map(\.title) == [PageDeveloperTools.title])
        let row = try #require(menu.items.first)
        _ = (row.target as? NSObject)?.perform(row.action)
        #expect(recorder.inspected.first === view)
        #expect(finished == 1)

        view.refusesProbes = true
        shown = nil
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "", isEditable: false) { finished += 1 }))
        #expect(shown == nil)
        #expect(finished == 2)
    }
}
