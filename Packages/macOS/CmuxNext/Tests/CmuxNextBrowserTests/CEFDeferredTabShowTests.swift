import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// NIGHTLY 1.0.0-nightly.4010547037301 (2026-10-24): a link clicked in an agent chat opened the
/// right pane's Chromium page empty, or drawn over only part of the pane until a divider drag.
/// Since PL-cef-tab a tab's browser is made after the frame commits (`CEFPaneHost.createDeferred`):
/// it joins the pane's live window (`tab_add`) or the window still being built (`windowCreated`).
/// Neither path did what `present` does for a tab with a browser: tell layer hosting which page
/// shows and post the geometry change that makes the fork's tracker place and clip the page window
/// over the host view now. A pane's split spring that lands without moving the host view's own
/// frame (its content is held at its rest size) must also leave the page at the landed frame.
///
/// `PageTracker` stands in for the fork's `CmuxParentViewTracker`: it reads the host view's geometry
/// on each `CmuxParentViewGeometryDidChange` post and each frame change of the host view itself, as
/// the tracker does while it follows a superview chain it no longer has (a same-window reparent).
@MainActor @Suite(.serialized) struct CEFDeferredTabShowTests {
    /// A link opens a tab in a pane whose Chromium window is live: it joins as the active tab in the
    /// one `tab_add` (no second activation), layer hosting shows its browser, and the page is placed.
    @Test func aTabJoiningALiveWindowAfterTheFrameIsActivatedOnceAndPlaced() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)
        let tracker = PageTracker(host.hostView)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        #expect(TabSpyShim.added.isEmpty, "the turn that shows the tab joins no window")
        TabSpyShim.activated = []
        tracker.reads = []
        host.createDeferred()

        #expect(TabSpyShim.added.map(\.anchor) == [10], "joined the pane's window after the frame")
        #expect(TabSpyShim.added.map(\.activate) == [1], "Chromium shows the new tab")
        #expect(link.browserID == TabSpyShim.addedBrowser)
        #expect(TabSpyShim.activated.isEmpty, "one activation source: tab_add's")
        #expect(host.lastActivated == TabSpyShim.addedBrowser, "its echo is this host's own")
        #expect(host.hostView.layerHosting.browser == TabSpyShim.addedBrowser, "layer hosting follows the shown page")
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "the page window is placed over the pane's view")
        _ = first
    }

    /// A tab the pane switched away from before its frame committed joins in the background:
    /// nothing activates it over the tab now shown.
    @Test func aTabNoLongerShownWhenItJoinsIsNotActivated() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.conceal(link)
        host.present(first, in: container)
        TabSpyShim.activated = []
        host.createDeferred()

        #expect(TabSpyShim.added.map(\.anchor) == [10])
        #expect(TabSpyShim.added.map(\.activate) == [0])
        #expect(TabSpyShim.activated.isEmpty)
        #expect(host.lastActivated == 10)
        #expect(host.hostView.layerHosting.browser == 10)
    }

    /// The Codex review's P1: a second tab shown while the pane's first Chromium window is still
    /// being built joins when the window comes up; it is the page shown, placed over the view.
    @Test func aTabQueuedWhileTheWindowIsBuiltIsShownWhenItComesUp() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        var endOfTurn: [@MainActor @Sendable () -> Void] = []
        host.endOfTurn = { endOfTurn.append($0) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        #expect(host.isCreatingWindow)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()
        #expect(link.browserID == nil && link.isCreationPending, "waits for the window")
        let tracker = PageTracker(host.hostView)
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        for block in endOfTurn { block() }

        #expect(link.browserID == TabSpyShim.addedBrowser)
        #expect(TabSpyShim.added.map(\.activate) == [1], "joined as Chromium's active tab")
        #expect(TabSpyShim.activated.isEmpty, "one activation source: tab_add's")
        #expect(host.lastActivated == TabSpyShim.addedBrowser)
        #expect(host.hostView.layerHosting.browser == TabSpyShim.addedBrowser, "layer hosting shows the shown tab, not the window's first")
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "the shown page is placed over the pane's view")
    }

    /// The Codex review's P1 at 132e71cd: the pane's first tab closes while its Chromium window is
    /// built and a second tab waits for that window. The late browser of the closed tab is closed,
    /// never shown, and the waiting tab asks for a window of its own: it gets its browser, is
    /// Chromium's active tab and is placed over the pane's view (it waited forever, the pane blank).
    @Test func aTabQueuedForAWindowWhoseFirstTabClosedGetsAWindowOfItsOwn() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        var endOfTurn: [@MainActor @Sendable () -> Void] = []
        host.endOfTurn = { endOfTurn.append($0) }
        func endTurn() { while !endOfTurn.isEmpty { endOfTurn.removeFirst()() } }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        let firstRequest = try #require(runtime.pendingWindows.keys.first)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()
        #expect(link.browserID == nil && link.isCreationPending, "waits for the window")
        first.close()
        runtime.handle(.afterCreated(browser: 10, request: firstRequest, window: 1))
        #expect(TabSpyShim.closed == [10], "the closed tab's late browser closes")
        endTurn()

        #expect(TabSpyShim.createWindowCalls == 2, "the waiting tab asked for a window of its own")
        let secondRequest = try #require(runtime.pendingWindows.keys.first)
        let tracker = PageTracker(host.hostView)
        runtime.handle(.afterCreated(browser: 12, request: secondRequest, window: 2))
        endTurn()
        runtime.handle(.beforeClose(browser: 10))

        #expect(host.isLive)
        #expect(link.browserID == 12)
        #expect(host.lastActivated == 12, "the new window's own tab is its active one")
        #expect(TabSpyShim.added.isEmpty)
        #expect(host.hostView.layerHosting.browser == 12, "layer hosting shows the waiting tab")
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "the page is placed over the pane's view")
        #expect(TabSpyShim.closed == [10], "only the late browser closed")
    }

    /// A link opened from an agent chat into a new right pane: the pane grows in on its split spring
    /// while the window is built, its content held at the rest size, so only its ancestors move. When
    /// the window comes up, and again when the spring lands, the page is placed at the pane's frame.
    @Test func aPageOpenedIntoAPaneGrowingInIsPlacedAtThePaneWhenTheWindowComesUpAndWhenItLands() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        var endOfTurn: [@MainActor @Sendable () -> Void] = []
        host.endOfTurn = { endOfTurn.append($0) }
        // The pane (its clip) on the screen's content, and the tab's content held at the pane's rest width.
        let screen = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let pane = NSView(frame: NSRect(x: 900, y: 0, width: 0, height: 600))
        screen.addSubview(pane)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = NSRect(x: -640, y: 0, width: 640, height: 600)
        pane.addSubview(tab.container)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        let tracker = PageTracker(host.hostView)

        // A spring frame: the pane grew to half its width; the held content rides its trailing edge.
        pane.frame = NSRect(x: 580, y: 0, width: 320, height: 600)
        tab.container.setFrameOrigin(NSPoint(x: -320, y: 0))
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        for block in endOfTurn { block() }
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "placed where the pane is when the window comes up")

        // The spring lands: the pane is at its rest frame; the content's size never changed.
        tracker.reads = []
        pane.frame = NSRect(x: 260, y: 0, width: 640, height: 600)
        tab.container.setFrameOrigin(.zero)
        #expect(tracker.reads.isEmpty, "the host view's own frame did not change")
        tab.container.notifyPaneMotionSettled()
        let landed = try #require(tracker.reads.last)
        #expect(landed == CEFHostGeometry(of: host.hostView))
        #expect(landed.screenRect == NSRect(x: 260, y: 0, width: 640, height: 600), "the page fills the pane, not a mid-motion part of it")
    }

    /// A divider drag resizes the pane: the page follows the host view's new frame.
    @Test func aDividerDragKeepsThePageAtTheHostBounds() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        let tracker = PageTracker(host.hostView)

        tab.container.setFrameSize(NSSize(width: 420, height: 600))
        #expect(host.hostView.frame == tab.container.bounds)
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView))
        #expect(tracker.reads.last?.screenRect.size == NSSize(width: 420, height: 600))
    }

    // MARK: Fixtures

    /// A runtime that outlives the test: a shown tab schedules work (its side panel refresh) that
    /// reads its runtime through an unowned reference after the test returned.
    private static func runtime() throws -> (CEFRuntime, URL) {
        TabSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-deferred-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try TabSpyShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        TabSpyShim.runtime = runtime
        return (runtime, root)
    }

    private static func host(_ runtime: CEFRuntime) -> CEFPaneHost {
        CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
    }

    /// A pane showing a Chromium page in its live window (browser 10).
    private static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
        let host = host(runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        #expect(host.isLive)
        #expect(first.browserID == 10)
        #expect(host.hostView.layerHosting.browser == 10)
        return (host, first, container)
    }
}

/// The fork tracker's reads of one host view (see the suite's comment).
@MainActor private final class PageTracker: NSObject {
    var reads: [CEFHostGeometry] = []
    private let view: CEFHostView

    init(_ view: CEFHostView) {
        self.view = view
        super.init()
        view.postsFrameChangedNotifications = true
        for name in [CEFHostView.geometryDidChange, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(read), name: name, object: view)
        }
    }

    @objc private func read() {
        reads.append(CEFHostGeometry(of: view))
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` reports the browser started,
/// `cmux_shim_tab_add` records the window's browser it joins and its activate flag and, as
/// production's shim does, runs the new tab's OnAfterCreated before it returns `addedBrowser`;
/// `cmux_shim_tab_activate` and `cmux_shim_close` record the browser, `cmux_shim_create_window` its calls; `cmux_shim_fork_api_version` reports layer hosting
/// (API 27, so a host's `CEFLayerHosting` follows the shown browser); every other function does
/// nothing and returns 0.
private nonisolated enum TabSpyShim {
    static let addedBrowser: Int32 = 11
    nonisolated(unsafe) static var added: [(anchor: Int32, activate: Int32)] = []
    nonisolated(unsafe) static var activated: [Int32] = []
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var createWindowCalls = 0
    nonisolated(unsafe) static weak var runtime: CEFRuntime?

    static func reset() {
        added = []
        activated = []
        closed = []
        createWindowCalls = 0
        runtime = nil
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            TabSpyShim.createWindowCalls += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, activate in
            TabSpyShim.added.append((anchor, activate))
            MainActor.assumeIsolated {
                TabSpyShim.runtime?.handle(.afterCreated(browser: TabSpyShim.addedBrowser, request: 0, window: 1))
            }
            return TabSpyShim.addedBrowser
        }
        let tabActivate: @convention(c) (Int32) -> Int32 = { browser in
            TabSpyShim.activated.append(browser)
            return 1
        }
        let close: @convention(c) (Int32) -> Void = { browser in TabSpyShim.closed.append(browser) }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_activate": unsafeBitCast(tabActivate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
