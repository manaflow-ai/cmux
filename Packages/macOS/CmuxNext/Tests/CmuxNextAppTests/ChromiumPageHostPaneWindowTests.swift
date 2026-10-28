@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextInput
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// The app's glue: a page made for a ``PageChromiumWindow`` takes the CEF pane key
/// `ChromiumPageHost.pane(of:)` names (``CEFEngine/pagesPane(window:pane:)``), so five pages of one pane are one host and
/// one Chromium window; a page with no pane has a window of its own; `CEFPageChromiumPage.moveWindow(to:)` moves the
/// tab to the other pane's host and back. Pages are made through `ChromiumPageHost.tabConfiguration` and
/// `CEFEngine.makeReadyTab` on a runtime over a stand-in shim that keeps which window holds each browser.
@MainActor @Suite(.serialized) struct ChromiumPageHostPaneWindowTests {
    private let paneA = PageChromiumWindow(window: "window-1", pane: "pane-a")
    private let paneB = PageChromiumWindow(window: "window-1", pane: "pane-b")

    @Test func fivePagesOfOnePaneAreOneHostAndAMoveGivesTwo() throws {
        let rig = try Rig()
        defer { rig.close() }
        let start = rig.runtime.hosts.count
        let pages = try (0..<5).map { _ in try rig.page(in: paneA) }
        let hostA = pages[0].tab.host
        #expect(hostA.key.pane == CEFEngine.pagesPane(window: "window-1", pane: "pane-a"))
        #expect(rig.runtime.hosts.count == start + 1, "five pages of one pane are one host")
        #expect(pages.allSatisfy { $0.tab.host === hostA })
        #expect(PaneWindowShim.createWindowCalls == 1, "the pane's second to fifth pages built a window")

        let moved = pages[4]
        moved.moveWindow(to: paneB)
        #expect(rig.runtime.hosts.count == start + 2, "a move gives two hosts")
        #expect(moved.tab.host.key.pane == CEFEngine.pagesPane(window: "window-1", pane: "pane-b"))
        #expect(rig.runtime.hosts[moved.tab.host.key] === moved.tab.host)

        moved.moveWindow(to: paneA)
        #expect(rig.runtime.hosts.count == start + 1, "the emptied host left the routing table")
        #expect(moved.tab.host === hostA && hostA.tabs.count == 5)
        #expect(PaneWindowShim.createWindowCalls == 1)
    }

    @Test func aPageWithNoPaneHasAWindowOfItsOwn() throws {
        let rig = try Rig()
        defer { rig.close() }
        let start = rig.runtime.hosts.count
        let shared = try rig.page(in: paneA)
        let first = try rig.page(in: nil)
        let second = try rig.page(in: nil)
        #expect(rig.runtime.hosts.count == start + 3)
        #expect(first.tab.host !== second.tab.host && first.tab.host !== shared.tab.host)
        #expect(first.tab.host.key.pane != second.tab.host.key.pane)
        #expect(PaneWindowShim.createWindowCalls == 3)
    }

    @MainActor final class Rig {
        let runtime: CEFRuntime
        let engine: CEFEngine
        let root: URL
        private var nextWindow: Int32 = 10
        private var nextBrowser: Int32 = 100

        init() throws {
            PaneWindowShim.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-pane-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try PaneWindowShim.library(), storage: CEFProfileStorage(root: root))
            // A window that came up shows itself at the end of the turn: the runtime outlives the test.
            _ = Unmanaged.passRetained(runtime)
            engine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
        }

        /// A page in `window`'s page window whose browser exists: the window's first page builds it (AFTER_CREATED),
        /// a later one joins it (`cmux_shim_tab_add`).
        func page(in window: PageChromiumWindow?) throws -> CEFPageChromiumPage {
            let configuration = ChromiumPageHost.tabConfiguration(of: engine, chatOpen: nil, window: window)
            let tab = engine.makeReadyTab(configuration, in: runtime)
            tab.host.ensureCreated(tab)
            if let request = runtime.pendingWindows.keys.first {
                let browser = nextBrowser, chromiumWindow = nextWindow
                nextBrowser += 1
                nextWindow += 1
                PaneWindowShim.windowOf[browser] = chromiumWindow
                runtime.handle(.afterCreated(browser: browser, request: request, window: chromiumWindow))
            }
            try #require(tab.browserID != nil)
            return CEFPageChromiumPage(tab: tab, pageID: "cmux.markdown", mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Stand-in shim functions that keep which Chromium window holds each browser: `cmux_shim_create_window` reports the
/// window started (the rig sends its OnAfterCreated), `cmux_shim_tab_add` makes a browser in its anchor's window,
/// `cmux_shim_tab_move_to_window` moves one into its anchor's window, `cmux_shim_tab_window_id` answers from that table,
/// and the fork is API 3. Every other function does nothing and returns 0.
private nonisolated enum PaneWindowShim {
    nonisolated(unsafe) static var windowOf: [Int32: Int32] = [:]
    nonisolated(unsafe) static var nextAdded: Int32 = 500
    nonisolated(unsafe) static var createWindowCalls = 0

    static func reset() {
        windowOf = [:]
        nextAdded = 500
        createWindowCalls = 0
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            PaneWindowShim.createWindowCalls += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, _ in
            let browser = PaneWindowShim.nextAdded
            PaneWindowShim.nextAdded += 1
            PaneWindowShim.windowOf[browser] = PaneWindowShim.windowOf[anchor]
            return browser
        }
        let tabMove: @convention(c) (Int32, Int32, Int32) -> Int32 = { browser, anchor, _ in
            PaneWindowShim.windowOf[browser] = PaneWindowShim.windowOf[anchor]
            return 1
        }
        let tabWindowID: @convention(c) (Int32) -> Int32 = { browser in PaneWindowShim.windowOf[browser] ?? 0 }
        let forkAPIVersion: @convention(c) () -> Int32 = { 3 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_move_to_window": unsafeBitCast(tabMove, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_window_id": unsafeBitCast(tabWindowID, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
