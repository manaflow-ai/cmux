@testable import CmuxNextBrowser
import Foundation
import Testing

/// The cmux page tabs of one pane share one Chromium window (`CEFEngine.pagesPane(window:pane:)`), as
/// one Chrome `Browser` holds its whole tab strip (chrome/browser/ui/browser.h). Five page tabs of a pane are one host
/// and one window; a tab moved to another pane moves into that pane's window with its document
/// (`cmux_tab_move_to_window`, the popup move path), which gives two; moving it back empties the second host, which
/// leaves the routing table (`CEFRuntime.hostEmptied`). Driven against a stand-in shim that keeps which window holds
/// each browser.
@MainActor @Suite(.serialized) struct CEFPagesPaneWindowTests {
    private let pages = BrowserProfileID(rawValue: UUID())
    private let paneA = CEFEngine.pagesPane(window: "window-1", pane: "pane-a")
    private let paneB = CEFEngine.pagesPane(window: "window-1", pane: "pane-b")

    private func key(_ pane: BrowserPaneID) -> CEFPaneKey { CEFPaneKey(pane: pane, profile: pages, offTheRecord: true) }

    @Test func fivePagesOfOnePaneShareOneHostAndOneWindow() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = runtime.hosts.count
        let tabs = try openFive(in: key(paneA), runtime: runtime)
        let host = try #require(runtime.hosts[key(paneA)])
        #expect(runtime.hosts.count == start + 1, "five page tabs of one pane are one host")
        #expect(tabs.allSatisfy { $0.host === host })
        #expect(host.tabs.count == 5)
        #expect(PagesPaneShim.createWindowCalls == 1, "the pane's second to fifth pages built a window")
        #expect(Set(tabs.compactMap { $0.browserID.flatMap { PagesPaneShim.windowOf[$0] } }) == [Self.windowA])
    }

    @Test func aMoveGivesTwoHostsAndMovingBackClosesTheEmptyOne() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = runtime.hosts.count
        let tabs = try openFive(in: key(paneA), runtime: runtime)
        let hostA = try #require(runtime.hosts[key(paneA)])
        let moved = tabs[4]
        let browser = try #require(moved.browserID)

        #expect(moved.moveToPagesPane(paneB))
        let hostB = try #require(runtime.hosts[key(paneB)])
        #expect(runtime.hosts.count == start + 2, "a move gives two hosts")
        #expect(moved.host === hostB && hostB.tabs.count == 1 && hostB.tabs.first === moved)
        #expect(hostA.tabs.count == 4)
        #expect(moved.awaitsWindowMove, "hidden: it moves into B's window when it shows there")
        #expect(PagesPaneShim.createWindowCalls == 1, "no window for a hidden tab")

        // The tab shows in pane B: B builds its window around a placeholder after the frame commits, never in the
        // show's turn (PL-cef-tab); the tab moves in, the placeholder closes.
        hostB.present(moved, in: moved.container)
        #expect(PagesPaneShim.createWindowCalls == 1, "the show's turn built a window")
        #expect(hostB.deferredCreations.contains { $0.tab === moved })
        #expect(runtime.pendingWindows.isEmpty)
        hostB.createDeferred()
        #expect(PagesPaneShim.createWindowCalls == 2, "the after-commit step builds B's window")
        let request = try #require(runtime.pendingWindows.keys.first)
        PagesPaneShim.windowOf[Self.placeholderB] = Self.windowB
        runtime.handle(.afterCreated(browser: Self.placeholderB, request: request, window: Self.windowB))
        hostB.movePopupsIn()
        #expect(PagesPaneShim.moves.last?.browser == browser && PagesPaneShim.moves.last?.anchor == Self.placeholderB)
        #expect(PagesPaneShim.windowOf[browser] == Self.windowB)
        #expect(!moved.awaitsWindowMove)
        runtime.handle(.beforeClose(browser: Self.placeholderB))
        #expect(hostB.tabs.count == 1 && hostB.tabs.first === moved, "the placeholder closed")
        #expect(runtime.hosts.count == start + 2)

        // Back to pane A: B is empty and leaves the table; the tab moves into A's live window.
        #expect(moved.moveToPagesPane(paneA))
        #expect(runtime.hosts[key(paneB)] == nil, "the emptied host left the routing table")
        #expect(runtime.hosts.count == start + 1)
        #expect(moved.host === hostA && hostA.tabs.count == 5)
        #expect(moved.awaitsWindowMove)
        hostA.movePopupsIn()
        #expect(PagesPaneShim.windowOf[browser] == Self.windowA)
        #expect(!moved.awaitsWindowMove)
        #expect(PagesPaneShim.createWindowCalls == 2)
    }

    /// Moved to pane B and back before it showed there: it never left A's Chromium window, so nothing moves and no
    /// window is built.
    @Test func aTabMovedBackBeforeItShowedStaysInItsWindow() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = runtime.hosts.count
        let tabs = try openFive(in: key(paneA), runtime: runtime)
        let hostA = try #require(runtime.hosts[key(paneA)])
        let moved = tabs[2]

        #expect(moved.moveToPagesPane(paneB))
        #expect(moved.moveToPagesPane(paneA))
        #expect(runtime.hosts.count == start + 1)
        #expect(moved.host === hostA && hostA.tabs.contains { $0 === moved })
        #expect(!moved.awaitsWindowMove, "it is in A's window already")
        #expect(PagesPaneShim.moves.isEmpty)
        #expect(PagesPaneShim.createWindowCalls == 1)
    }

    /// A fork before `cmux_tab_move_to_window` (API 3) and a tab with no browser yet cannot move: they stay.
    @Test func aTabThatCannotMoveStaysInItsHost() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let tabs = try openFive(in: key(paneA), runtime: runtime)
        let hostA = try #require(runtime.hosts[key(paneA)])
        let unborn = CEFTab(id: .random(), profile: pages, host: hostA, runtime: runtime)
        hostA.add(unborn)
        #expect(!unborn.moveToPagesPane(paneB))
        #expect(unborn.host === hostA)

        PagesPaneShim.forkAPI = 2
        #expect(!tabs[0].moveToPagesPane(paneB))
        #expect(tabs[0].host === hostA)
        #expect(runtime.hosts[key(paneB)] == nil)
        #expect(tabs[0].moveToPagesPane(paneA), "its own pane: nothing to move")
    }

    private static let windowA: Int32 = 10
    private static let windowB: Int32 = 20
    private static let firstA: Int32 = 100
    private static let placeholderB: Int32 = 300

    /// Opens five page tabs of `key`: the first builds the window, the other four join it (`cmux_shim_tab_add`).
    private func openFive(in key: CEFPaneKey, runtime: CEFRuntime) throws -> [CEFTab] {
        let host = runtime.host(for: key)
        let first = CEFTab(id: .random(), profile: key.profile, host: host, runtime: runtime)
        host.add(first)
        host.ensureCreated(first)
        let request = try #require(runtime.pendingWindows.keys.first)
        PagesPaneShim.windowOf[Self.firstA] = Self.windowA
        runtime.handle(.afterCreated(browser: Self.firstA, request: request, window: Self.windowA))
        #expect(first.browserID == Self.firstA)
        var tabs = [first]
        for _ in 0..<4 {
            let joined = runtime.host(for: key)
            let tab = CEFTab(id: .random(), profile: key.profile, host: joined, runtime: runtime)
            joined.add(tab)
            joined.ensureCreated(tab)
            #expect(tab.browserID != nil)
            tabs.append(tab)
        }
        return tabs
    }

    /// A runtime that outlives the test (a window that came up shows itself at the end of the turn), on a fresh shim.
    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        PagesPaneShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-pages-pane-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try PagesPaneShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim functions that keep which Chromium window holds each browser: `cmux_shim_create_window` reports
/// the window started (a test sends its OnAfterCreated), `cmux_shim_tab_add` makes a browser in its anchor's window,
/// `cmux_shim_tab_move_to_window` moves one into its anchor's window, `cmux_shim_tab_window_id` answers from that
/// table, and `cmux_shim_fork_api_version` answers ``forkAPI``. Every other function does nothing and returns 0.
private nonisolated enum PagesPaneShim {
    nonisolated(unsafe) static var windowOf: [Int32: Int32] = [:]
    nonisolated(unsafe) static var nextBrowser: Int32 = 200
    nonisolated(unsafe) static var moves: [(browser: Int32, anchor: Int32)] = []
    nonisolated(unsafe) static var createWindowCalls = 0
    nonisolated(unsafe) static var forkAPI: Int32 = 3

    static func reset() {
        windowOf = [:]
        nextBrowser = 200
        moves = []
        createWindowCalls = 0
        forkAPI = 3
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            PagesPaneShim.createWindowCalls += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, _ in
            let browser = PagesPaneShim.nextBrowser
            PagesPaneShim.nextBrowser += 1
            PagesPaneShim.windowOf[browser] = PagesPaneShim.windowOf[anchor]
            return browser
        }
        let tabMove: @convention(c) (Int32, Int32, Int32) -> Int32 = { browser, anchor, _ in
            PagesPaneShim.moves.append((browser, anchor))
            PagesPaneShim.windowOf[browser] = PagesPaneShim.windowOf[anchor]
            return 1
        }
        let tabWindowID: @convention(c) (Int32) -> Int32 = { browser in PagesPaneShim.windowOf[browser] ?? 0 }
        let forkAPIVersion: @convention(c) () -> Int32 = { PagesPaneShim.forkAPI }
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
