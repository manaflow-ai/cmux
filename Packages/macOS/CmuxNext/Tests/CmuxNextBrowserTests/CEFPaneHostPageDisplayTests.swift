import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 221 of plans/cmux-next/chrome-parity/p01-process.md: in host mode the page's window lives in
/// the Chromium Host and is never ordered in, so cmux places it on the display its page view shows
/// on (`cmux_shim_browser_set_page_display`), and Chromium's begin-frames, device scale factor and
/// color space follow that display, as Chrome's browser process follows the display its app shim
/// reports (`RenderWidgetHostNSViewHost::OnScreenInfosChanged`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFPaneHostPageDisplayTests {
    @Test func thePageWindowFollowsThePageViewsDisplay() throws {
        let runtime = try Self.runtime(forkAPI: 31)
        let (host, tab) = try Self.livePane(runtime)
        let page = try #require(host.hostedPageView)
        var display = Self.display(id: 5, hz: 120)
        page.screenInfoSource = { _ in display }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.present(tab, in: container)
        #expect(DisplaySpy.calls.isEmpty, "no window: no display to place the page on")

        let window = Self.window()
        defer { container.removeFromSuperview(); window.close() }
        window.contentView?.addSubview(container)
        let origin = try #require(page.presentedScreenRect?.origin)
        #expect(DisplaySpy.calls == [.init(browser: Self.firstBrowser, display: 5, x: Double(origin.x), y: Double(origin.y))])

        // The window moved to a 60 Hz display: the page window goes there.
        display = Self.display(id: 6, hz: 60)
        page.screenParametersChanged()
        #expect(DisplaySpy.calls.map(\.display) == [5, 6])

        // Nothing changed: nothing is sent.
        page.screenParametersChanged()
        #expect(DisplaySpy.calls.count == 2)

        // A new page window (a restarted host's) is placed with its context, on the view's display.
        host.showHostedContext(of: Self.firstBrowser + 1)
        #expect(DisplaySpy.calls.last?.browser == Self.firstBrowser + 1)
        #expect(DisplaySpy.calls.last?.display == 6)
    }

    /// The workspace was switched away, its window moved to another display, then switched back: the
    /// page view enters the window before the pane shows the tab again (`present` adds the host view
    /// first), so the display it reads then has no browser to go to. Showing the tab places the page.
    @Test func aTabShownAgainOnAnotherDisplayPlacesThePageThere() throws {
        let runtime = try Self.runtime(forkAPI: 31)
        let (host, tab) = try Self.livePane(runtime)
        let page = try #require(host.hostedPageView)
        var display = Self.display(id: 5, hz: 120)
        page.screenInfoSource = { _ in display }
        let first = Self.window()
        let shown = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        first.contentView?.addSubview(shown)
        host.present(tab, in: shown)
        #expect(DisplaySpy.calls.map(\.display) == [5])

        // Switched away: the tab's content view leaves its window.
        host.conceal(tab)
        shown.removeFromSuperview()

        // Back, in a window on a 60 Hz 1x display.
        display = ChromiumHostScreenInfo(displayID: 6, scaleMilli: 1_000, colorSpaceHash: 2, maximumFramesPerSecond: 60,
                                         workArea: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
        let second = Self.window()
        let back = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        second.contentView?.addSubview(back)
        defer { back.removeFromSuperview(); first.close(); second.close() }
        host.present(tab, in: back)

        let origin = try #require(page.presentedScreenRect?.origin)
        #expect(DisplaySpy.calls.last == DisplaySpy.Call(browser: Self.firstBrowser, display: 6, x: Double(origin.x), y: Double(origin.y)))
        #expect(DisplaySpy.calls.count == 2)
        #expect(page.placedScreenInfo == display)

        // Shown again on the same display: nothing more goes.
        page.screenParametersChanged()
        host.present(tab, in: back)
        #expect(DisplaySpy.calls.count == 2)
    }

    /// Below fork API 31 the fork has no page display call: nothing goes to the host.
    @Test func anOlderForkGetsNoPageDisplay() throws {
        let runtime = try Self.runtime(forkAPI: 30)
        let (host, tab) = try Self.livePane(runtime)
        let page = try #require(host.hostedPageView)
        page.screenInfoSource = { _ in Self.display(id: 5, hz: 120) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.present(tab, in: container)
        let window = Self.window()
        defer { container.removeFromSuperview(); window.close() }
        window.contentView?.addSubview(container)

        #expect(page.screenInfo?.displayID == 5)
        #expect(DisplaySpy.calls.isEmpty)
    }

    // MARK: Fixtures

    private static let firstBrowser: Int32 = 1

    private static func display(id: UInt32, hz: Int) -> ChromiumHostScreenInfo {
        ChromiumHostScreenInfo(displayID: id, scaleMilli: 2_000, colorSpaceHash: 1, maximumFramesPerSecond: hz,
                               workArea: CGRect(x: 0, y: 0, width: 1512, height: 944))
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A host-mode runtime that outlives the test (a pane's scheduled work reads it through an unowned reference).
    private static func runtime(forkAPI: Int32) throws -> CEFRuntime {
        DisplaySpy.reset(forkAPI: forkAPI)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-page-display-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(DisplaySpy.symbol), storage: CEFProfileStorage(root: root))
        let hostStart = CEFHostStart(supervisor: DisplayNoHost(), clock: ContinuousClock())
        hostStart.mapsClientIDs = true
        runtime.hostStart = hostStart
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    private static func livePane(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })
        runtime.handle(.afterCreated(browser: firstBrowser, request: request, window: 1))
        #expect(tab.browserID == firstBrowser)
        return (host, tab)
    }
}

/// Never attaches: these tests drive panes against the spy shim and never start Chromium.
@MainActor private final class DisplayNoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim functions: `browser_set_page_display` records its calls, `fork_api_version`
/// reports the test's fork API, every other function does nothing and returns 0.
private nonisolated enum DisplaySpy {
    struct Call: Equatable {
        var browser: Int32
        var display: UInt32
        var x: Double
        var y: Double
    }

    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var forkAPI: Int32 = 31

    static func reset(forkAPI: Int32) {
        calls = []
        self.forkAPI = forkAPI
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { 0 }
        let setPageDisplay: @convention(c) (Int32, UInt32, Double, Double) -> Int32 = { browser, display, x, y in
            DisplaySpy.calls.append(Call(browser: browser, display: display, x: x, y: y))
            return 1
        }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, _, _, _, _, _ in 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { DisplaySpy.forkAPI }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_page_display": unsafeBitCast(setPageDisplay, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
