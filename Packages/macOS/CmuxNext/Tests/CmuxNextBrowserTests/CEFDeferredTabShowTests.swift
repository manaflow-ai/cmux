import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// NIGHTLY 1.0.0-nightly.4010547037301 (2026-10-24): a link clicked into a pane that already shows
/// a Chromium tab opened an empty pane. Since PL-cef-tab the new tab's browser joins the pane's
/// live Chromium window after the frame commits (`CEFPaneHost.createDeferred`, `tab_add`), and that
/// path skipped what `present` does for a tab with a browser: activate it in Chromium, tell layer
/// hosting which page shows, and post the geometry change that puts the page window over the view.
@MainActor @Suite(.serialized) struct CEFDeferredTabShowTests {
    @Test func aTabJoiningALiveWindowAfterTheFrameIsActivatedAndPlaced() async throws {
        TabSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-deferred-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try TabSpyShim.library(), storage: CEFProfileStorage(root: root))
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // The pane shows a Chromium page: its window is live.
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 10, request: request, window: 1))
        #expect(host.isLive)
        #expect(first.browserID == 10)

        // A link opens a new tab in that pane.
        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        #expect(TabSpyShim.added.isEmpty, "the turn that shows the tab joins no window")
        TabSpyShim.activated = []
        let posts = CEFHostView.trackerStats.geometryPosts
        host.createDeferred()

        #expect(TabSpyShim.added == [10], "joined the pane's window after the frame")
        #expect(link.browserID == TabSpyShim.addedBrowser)
        #expect(TabSpyShim.activated == [TabSpyShim.addedBrowser], "Chromium shows the new tab")
        #expect(host.lastActivated == TabSpyShim.addedBrowser)
        #expect(CEFHostView.trackerStats.geometryPosts > posts, "the page window is placed over the pane's view")
        // The side panel refresh a shown tab schedules reads the runtime (unowned): let it run first.
        for _ in 0..<5 { await Task.yield() }
        withExtendedLifetime((runtime, host)) {}
    }

    /// A tab the pane switched away from before its frame committed joins in the background:
    /// nothing activates it over the tab now shown.
    @Test func aTabNoLongerShownWhenItJoinsIsNotActivated() async throws {
        TabSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-deferred-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try TabSpyShim.library(), storage: CEFProfileStorage(root: root))
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.conceal(link)
        host.present(first, in: container)
        TabSpyShim.activated = []
        host.createDeferred()

        #expect(TabSpyShim.added == [10])
        #expect(TabSpyShim.activated.isEmpty)
        #expect(host.lastActivated == 10)
        for _ in 0..<5 { await Task.yield() }
        withExtendedLifetime((runtime, host)) {}
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` reports the browser started,
/// `cmux_shim_tab_add` records the window's browser it joins and returns `addedBrowser`,
/// `cmux_shim_tab_activate` records the browser; every other function does nothing and returns 0.
private nonisolated enum TabSpyShim {
    static let addedBrowser: Int32 = 11
    nonisolated(unsafe) static var added: [Int32] = []
    nonisolated(unsafe) static var activated: [Int32] = []

    static func reset() {
        added = []
        activated = []
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, _ in
            TabSpyShim.added.append(anchor)
            return TabSpyShim.addedBrowser
        }
        let tabActivate: @convention(c) (Int32) -> Int32 = { browser in
            TabSpyShim.activated.append(browser)
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_activate": unsafeBitCast(tabActivate, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
