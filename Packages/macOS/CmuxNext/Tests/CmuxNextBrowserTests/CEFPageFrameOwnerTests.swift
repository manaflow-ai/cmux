import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S5 (cmux-ad m14, Lawrence 2026-11-05: "during key resizes AND divider drags, in every frame every
/// browser shows live pixels rendered at that frame's pane size"). With `motion.frameOwner.pages` on, a Chromium page is
/// hosted in the window's own layer tree (fork API 26) and never keeps an old size through a pane resize: in every step of
/// a key resize and of a divider drag its host view takes the pane's page area. The main thread never waits for the page
/// (lead, cmux-ad m14): Chromium's resize wait runs on its UI thread, the app's main thread, so S5 gives every page window
/// a deadline of 0 (fork API 27: no pre-commit wait, no GPU transaction, no post-commit wait). Before S5 a key resize held
/// the page at its start size (the old frame, anchored and clipped) and no page was hosted unless
/// `browserResize.layerHosting` was set.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFPageFrameOwnerTests {
    /// The longest a resize step's layout turn may take here (no Chromium, no display): one 120 Hz frame. A turn that
    /// waited for a page (up to the 16 ms drag deadline before the cap) would pass it.
    static let stepBudget = Duration.microseconds(8_333)

    /// A key resize with the switch on: the page follows its pane's page area in every step at the step's size (never the
    /// start size, never scaled), and no page window is asked to hold a commit for its frame.
    @Test func aKeyResizeShowsThePageAtThePanesSizeInEveryStep() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        let page = host.hostView
        try #require(page.superview === first.container && page.frame.width > 0, "SETUP: the page is not shown at a size")
        PageSpyShim.resizeSyncs = []

        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        #expect(first.container.heldPageSize == nil, "the page keeps its start size through the key resize (the old frame)")
        var misses: [String] = []
        let clock = ContinuousClock()
        // A held key press: the pane's leading edge moves right 120 pt and back past its start, as a key resize spring does.
        let steps: [CGFloat] = (0...12).map { CGFloat($0) * 10 } + (0...12).map { CGFloat(12 - 2 * $0) * 10 }
        for (index, dx) in steps.enumerated() {
            let started = clock.now
            first.container.frame = NSRect(x: 200 + dx, y: 0, width: 600 - dx, height: 500)
            first.container.layoutSubtreeIfNeeded()
            let took = clock.now - started
            if page.frame != first.container.bounds {
                misses.append("step \(index): page \(page.frame), pane page area \(first.container.bounds)")
            }
            if took > Self.stepBudget { misses.append("step \(index): the layout turn took \(took)") }
        }
        #expect(misses.isEmpty, "\(misses.count) of \(steps.count) steps do not show the page at its pane's size: \(misses.prefix(3))")
        #expect(PageSpyShim.resizeSyncs.allSatisfy { $0.timeoutMs == 0 }, "a page window may hold the main thread's commit: \(PageSpyShim.resizeSyncs)")

        first.container.holdPage(for: nil)
        first.container.layoutSubtreeIfNeeded()
        #expect(page.frame == first.container.bounds)
        #expect(!host.hostView.layerHosting.inPaneDrag, "the page sync ends with the key resize")
    }

    /// A divider drag with the switch on and `browserResize.dragResize` at its default: the page is hosted, lays out at every
    /// drag size, and no page window holds a commit for its frame.
    @Test func aDividerDragShowsTheHostedPageAtThePanesSizeInEveryStep() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        // The hosting request of a new page window runs at the end of the run-loop turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        #expect(PageSpyShim.hostingAsks.contains { $0.browser == 10 && $0.enabled }, "the page window was never asked to be hosted")
        let page = host.hostView
        PageSpyShim.resizeSyncs = []

        first.container.paneResizeGestureDidChange(active: true)
        #expect(first.container.heldPageSize == nil, "the page keeps its drag-start size")
        var misses: [String] = []
        for width in stride(from: CGFloat(600), through: 360, by: -20) {
            first.container.setFrameSize(NSSize(width: width, height: 500))
            first.container.layoutSubtreeIfNeeded()
            if page.frame != first.container.bounds { misses.append("width \(width): page \(page.frame)") }
        }
        #expect(misses.isEmpty, "\(misses.count) drag steps do not show the page at its pane's size: \(misses.prefix(3))")
        #expect(PageSpyShim.resizeSyncs.allSatisfy { $0.timeoutMs == 0 }, "a page window may hold the main thread's commit")
        first.container.paneResizeGestureDidChange(active: false)
        #expect(!host.hostView.layerHosting.inPaneDrag)
    }

    /// The switch on hosts every new page window in the window's layer tree, with `browserResize.layerHosting` at its
    /// default (off): the page's pixels commit with its pane.
    @Test func aNewPageWindowIsHostedInTheWindowsLayers() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
        let (hosting, fork, turn) = Self.hosting(intervals: [1.0 / 120])
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        turn.end()
        #expect(fork.calls.map(\.browser) == [3] && fork.calls.map(\.enabled) == [true], "the page window was not hosted")
        #expect(hosting.page?.contextID == 7)
        hosting.stop()
    }

    /// The page misses every frame (Chromium draws late): the main thread still commits each frame at once. The tunables
    /// that made a pane resize hold the commit before S5 (a hosted page's `syncDeadline`, the drag's `dragResizeDeadline`,
    /// both set high here) give the fork 0 with S5 on, so Chromium's pre-commit handler never waits on the main thread, and
    /// the hosted page is shown unscaled. `motion.frameOwner.pagesWait` above 0 (measurement only) stays under half a frame.
    @Test func aPageThatMissesItsFrameNeverHoldsTheMainThread() throws {
        Self.set(pages: true, syncDeadline: 0.05, dragDeadline: 0.05)
        defer { Self.set(pages: nil) }
        let (hosting, fork, turn) = Self.hosting(intervals: [1.0 / 120])
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        turn.end()
        let page = try #require(hosting.page, "SETUP: the page is not hosted")
        hosting.paneResizeDrag(active: true)
        hosting.paneResizeDrag(active: false)
        #expect(fork.syncs.allSatisfy { $0.timeoutMs == 0 }, "the fork was given a main-thread wait: \(fork.syncs)")
        #expect(page.layer?.affineTransform() == .identity && page.layer?.sublayers?.first?.affineTransform() == .identity,
                "the hosted page is scaled")

        // The measurement knob: a wait, but never past half the shortest display frame (4 ms at 120 Hz).
        Self.set(pages: true, pagesWait: 0.016)
        hosting.paneResizeDrag(active: true)
        #expect(fork.syncs.last?.timeoutMs == 4)
        hosting.paneResizeDrag(active: false)
        #expect(fork.syncs.last?.timeoutMs == 0)
        hosting.stop()
    }

    /// The switch off (the default) changes nothing: a key resize still holds the page's size (S3 and the interim rule).
    @Test func theSwitchOffKeepsTodaysKeyResizeHold() throws {
        Self.set(pages: false)
        defer { Self.set(pages: nil) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        let held = host.hostView.frame.size
        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        #expect(first.container.heldPageSize == held)
        #expect(!host.hostView.layerHosting.inPaneDrag)
        first.container.holdPage(for: nil)
    }

    // MARK: Fixtures

    /// The fork side for ``CEFLayerHosting`` alone: context 7, and every call.
    final class FakeFork {
        private(set) var calls: [(browser: Int32, enabled: Bool)] = []
        private(set) var syncs: [(browser: Int32, timeoutMs: Int32)] = []
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { [self] browser, enabled in
                calls.append((browser, enabled))
                return enabled ? 7 : 0
            }, setResizeSync: { [self] browser, timeout in
                syncs.append((browser, timeout))
                return true
            })
        }
    }

    /// Blocks waiting for the end of the run-loop turn.
    final class Turn {
        private var blocks: [@MainActor @Sendable () -> Void] = []
        func add(_ block: @escaping @MainActor @Sendable () -> Void) { blocks.append(block) }
        func end() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    /// A ``CEFLayerHosting`` with its default tunable reads, a fake fork and fixed display rates.
    private static func hosting(intervals: [Double]) -> (CEFLayerHosting, FakeFork, Turn) {
        let fork = FakeFork(), turn = Turn()
        let hosting = CEFLayerHosting(schedule: { turn.add($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      refreshIntervals: { intervals })
        hosting.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return (hosting, fork, turn)
    }

    /// Sets the S5 switch (nil: every tunable here at its default) and the waits it overrides.
    private static func set(pages: Bool?, syncDeadline: Double? = nil, dragDeadline: Double? = nil, pagesWait: Double? = nil) {
        let tunables = BrowserResizeTunables.self
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(tunables.all)
        TunableStore.shared.set(tunables.dragResize.key, nil)
        TunableStore.shared.set(tunables.framesOwnedByCommit.key, pages.map { .bool($0) })
        TunableStore.shared.set(tunables.syncDeadline.key, syncDeadline.map { .number($0) })
        TunableStore.shared.set(tunables.dragResizeDeadline.key, dragDeadline.map { .number($0) })
        TunableStore.shared.set(tunables.pagesWait.key, pagesWait.map { .number($0) })
    }

    /// A runtime that outlives the test (a shown tab schedules work that reads it after the test returned).
    private static func runtime() throws -> (CEFRuntime, URL) {
        PageSpyShim.resizeSyncs = []
        PageSpyShim.hostingAsks = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-s5-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try PageSpyShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A pane showing a Chromium page in its live window (browser 10).
    private static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        try #require(host.isLive && first.browserID == 10)
        return (host, first)
    }
}

/// Stand-in shim: `cmux_shim_create_window` reports the browser started, `cmux_shim_fork_api_version` reports fork API 27
/// (layer hosting and resize sync), `cmux_shim_browser_set_resize_sync` records the browser and deadline and takes it,
/// `cmux_shim_browser_set_layer_hosting` records the ask and refuses it (0: the page stays in its window here, as the fork
/// does before Chromium put the page in its window); every other function does nothing and returns 0.
private nonisolated enum PageSpyShim {
    nonisolated(unsafe) static var resizeSyncs: [(browser: Int32, timeoutMs: Int32)] = []
    nonisolated(unsafe) static var hostingAsks: [(browser: Int32, enabled: Bool)] = []

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let resizeSync: @convention(c) (Int32, Int32) -> Int32 = { browser, timeout in
            PageSpyShim.resizeSyncs.append((browser, timeout))
            return 1
        }
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { browser, enabled in
            PageSpyShim.hostingAsks.append((browser, enabled != 0))
            return 0
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_resize_sync": unsafeBitCast(resizeSync, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
