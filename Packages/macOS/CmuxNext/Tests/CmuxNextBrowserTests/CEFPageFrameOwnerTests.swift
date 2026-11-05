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
/// a key resize and of a divider drag its host view takes the pane's page area, and its page window holds the step's
/// commit for Chromium's frame at that size up to a bounded deadline (fork API 27), so the frame shows in the same commit
/// as its pane. Before S5 a key resize held the page at its start size (the old frame, anchored and clipped), a drag laid
/// it out with no wait (the page trails the divider), and no page was hosted unless `browserResize.layerHosting` was set.
///
/// The switch is set by its key, so this suite compiles where it does not exist yet and fails on behavior there.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFPageFrameOwnerTests {
    /// The S5 switch, by key (`BrowserResizeTunables.framesOwnedByCommit`).
    static let pagesSwitch = Tunable<Bool>.toggle(
        "motion.frameOwner.pages", BrowserResizeTunables.section, "Page frame and size in one commit (test)",
        help: "Test registration of the S5 switch.", default: false)

    /// A key resize with the switch on: the page follows its pane's page area in every step at the step's size (never the
    /// start size, never scaled), and its page window waits for its frame at that size through the whole resize.
    @Test func aKeyResizeShowsThePageAtThePanesSizeInEveryStep() throws {
        Self.setSwitch(true)
        defer { Self.setSwitch(nil) }
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
        // A held key press: the pane's leading edge moves right 120 pt and back past its start, as a key resize spring does.
        let steps: [CGFloat] = (0...12).map { CGFloat($0) * 10 } + (0...12).map { CGFloat(12 - 2 * $0) * 10 }
        for (index, dx) in steps.enumerated() {
            first.container.frame = NSRect(x: 200 + dx, y: 0, width: 600 - dx, height: 500)
            first.container.layoutSubtreeIfNeeded()
            if page.frame != first.container.bounds {
                misses.append("step \(index): page \(page.frame), pane page area \(first.container.bounds)")
            }
            if Self.deadline(of: 10) <= 0 { misses.append("step \(index): the page window does not wait for its frame") }
        }
        #expect(misses.isEmpty, "\(misses.count) of \(steps.count) steps do not show the page at its pane's size: \(misses.prefix(3))")

        first.container.holdPage(for: nil)
        first.container.layoutSubtreeIfNeeded()
        #expect(page.frame == first.container.bounds)
        #expect(!host.hostView.layerHosting.inPaneDrag, "the wait ends with the key resize")
    }

    /// A divider drag with the switch on and `browserResize.dragResize` at its default: the page lays out at every drag
    /// size, and its page window waits for its frame at each size from the first move until the release landed.
    @Test func aDividerDragShowsThePageAtThePanesSizeInEveryStep() throws {
        Self.setSwitch(true)
        defer { Self.setSwitch(nil) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        let page = host.hostView
        PageSpyShim.resizeSyncs = []

        first.container.paneResizeGestureDidChange(active: true)
        #expect(host.hostView.layerHosting.inPaneDrag, "the page window does not wait for its frame during the drag")
        #expect(first.container.heldPageSize == nil, "the page keeps its drag-start size")
        var misses: [String] = []
        for width in stride(from: CGFloat(600), through: 360, by: -20) {
            first.container.setFrameSize(NSSize(width: width, height: 500))
            first.container.layoutSubtreeIfNeeded()
            if page.frame != first.container.bounds { misses.append("width \(width): page \(page.frame)") }
            if Self.deadline(of: 10) <= 0 { misses.append("width \(width): no wait") }
        }
        #expect(misses.isEmpty, "\(misses.count) drag steps do not show the page at its pane's size: \(misses.prefix(3))")
        first.container.paneResizeGestureDidChange(active: false)
        #expect(!host.hostView.layerHosting.inPaneDrag)
    }

    /// The switch on hosts every new page window in the window's layer tree, with `browserResize.layerHosting` at its
    /// default (off): the page's pixels commit with its pane.
    @Test func aNewPageWindowIsHostedInTheWindowsLayers() throws {
        Self.setSwitch(true)
        defer { Self.setSwitch(nil) }
        let asks = Asks()
        let fork = CEFLayerHosting.Fork(setLayerHosting: { browser, enabled in
            asks.calls.append((browser, enabled))
            return enabled ? 7 : 0
        }, setResizeSync: { _, _ in true })
        var turn: [@MainActor @Sendable () -> Void] = []
        let hosting = CEFLayerHosting(schedule: { turn.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) })
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fork)
        for block in turn { block() }
        #expect(asks.calls.map(\.browser) == [3] && asks.calls.map(\.enabled) == [true], "the page window was not hosted")
        #expect(hosting.page?.contextID == 7)
        hosting.stop()
    }

    /// The switch off (the default) changes nothing: a key resize still holds the page's size (S3 and the interim rule).
    @Test func theSwitchOffKeepsTodaysKeyResizeHold() throws {
        Self.setSwitch(false)
        defer { Self.setSwitch(nil) }
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

    final class Asks {
        var calls: [(browser: Int32, enabled: Bool)] = []
    }

    /// The last resize-sync deadline the fork took for `browser`, 0 when none.
    private static func deadline(of browser: Int32) -> Int32 {
        PageSpyShim.resizeSyncs.last { $0.browser == browser }?.timeoutMs ?? 0
    }

    /// Sets the S5 switch (nil: its default) and leaves `browserResize.dragResize` at its default.
    private static func setSwitch(_ on: Bool?) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([pagesSwitch.descriptor, BrowserResizeTunables.dragResize.descriptor])
        TunableStore.shared.set(BrowserResizeTunables.dragResize.key, nil)
        TunableStore.shared.set(pagesSwitch.key, on.map { .bool($0) })
    }

    /// A runtime that outlives the test (a shown tab schedules work that reads it after the test returned).
    private static func runtime() throws -> (CEFRuntime, URL) {
        PageSpyShim.resizeSyncs = []
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
/// (layer hosting and resize sync), `cmux_shim_browser_set_resize_sync` records the browser and deadline and takes it;
/// every other function does nothing and returns 0 (layer hosting refused, so the page stays in its window here).
private nonisolated enum PageSpyShim {
    nonisolated(unsafe) static var resizeSyncs: [(browser: Int32, timeoutMs: Int32)] = []

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let resizeSync: @convention(c) (Int32, Int32) -> Int32 = { browser, timeout in
            PageSpyShim.resizeSyncs.append((browser, timeout))
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_resize_sync": unsafeBitCast(resizeSync, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
