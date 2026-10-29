import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// Task 046 of plans/cmux-next/chrome-parity/p01-process.md: a page the Chromium Host hosts
/// detached (no window of the host orders in) takes focus through the fork's embedder-active
/// state, never CEF's `SetFocus` (which makes the host's page window key and activates the host, an
/// app with cmux's bundle id). A page that is not detached (in process, or a host page before task
/// 053 detaches it) keeps `SetFocus`: its page window is the only one that can take its keys.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFTabHostFocusTests {
    @Test func aDetachedPageFocusIsEmbedderActiveNeverSetFocus() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        tab.hostDetachedPage(browser: Self.firstBrowser)

        tab.setFocused(true)
        tab.setFocused(true)  // a re-apply posts nothing new
        tab.setFocused(false)

        #expect(FocusSpy.embedderActive.map(\.active) == [1, 0])
        #expect(FocusSpy.embedderActive.allSatisfy { $0.browser == Self.firstBrowser })
        #expect(FocusSpy.setFocus.isEmpty, "SetFocus activates the host")
    }

    /// Before the host detaches the page, its page window is the only window that can take its
    /// keys: embedder-active would focus nothing.
    @Test func aHostPageNotDetachedKeepsSetFocus() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))

        tab.setFocused(true)
        tab.setFocused(false)

        #expect(FocusSpy.setFocus.map(\.focus) == [1, 0])
        #expect(FocusSpy.embedderActive.isEmpty, "embedder-active is the key state of a detached page only")
    }

    @Test func inProcessFocusIsSetFocus() throws {
        let runtime = try Self.runtime(hostMode: false)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        tab.hostDetachedPage(browser: Self.firstBrowser)  // no host: nothing is detached

        tab.setFocused(true)
        tab.setFocused(false)

        #expect(FocusSpy.setFocus.map(\.focus) == [1, 0])
        #expect(FocusSpy.embedderActive.isEmpty)
    }

    /// Focus asked for before the browser exists applies at its AFTER_CREATED, the way the page
    /// takes focus then (not detached yet: `SetFocus`).
    @Test func hostModePendingFocusAppliesAtAttach() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = Self.pane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        tab.setFocused(true)
        #expect(FocusSpy.setFocus.isEmpty, "no browser yet")
        let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })

        runtime.handle(.afterCreated(browser: Self.firstBrowser, request: request, window: 1))

        #expect(FocusSpy.setFocus.map(\.focus) == [1])
        #expect(FocusSpy.embedderActive.isEmpty)
    }

    /// Focus asked for before the host detached the page moves to embedder-active when it does.
    @Test func focusAskedBeforeTheDetachAppliesAfterIt() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        tab.setFocused(true)
        #expect(FocusSpy.embedderActive.isEmpty, "not detached yet")

        tab.hostDetachedPage(browser: Self.firstBrowser)
        tab.hostDetachedPage(browser: Self.firstBrowser)  // a repeat posts nothing new

        #expect(FocusSpy.embedderActive.map(\.active) == [1])
    }

    /// A detach of a page that does not have focus focuses nothing.
    @Test func aDetachGivesNoFocusOfItsOwn() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))

        tab.hostDetachedPage(browser: Self.firstBrowser)

        #expect(FocusSpy.embedderActive.isEmpty)
        #expect(FocusSpy.setFocus.isEmpty)
    }

    /// A restarted host's browser has a new id: it is not detached until the host says so, and then
    /// it hears the state again.
    @Test func aNewBrowserIsNotDetachedUntilTheHostSaysSo() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        tab.hostDetachedPage(browser: Self.firstBrowser)
        tab.setFocused(true)

        let next = Self.firstBrowser + 1
        runtime.register(tab, browser: next)
        tab.hostDetachedPage(browser: Self.firstBrowser)  // the old browser's: ignored

        #expect(FocusSpy.setFocus.map(\.browser) == [next], "pending focus at the new attach, not detached yet")
        tab.hostDetachedPage(browser: next)
        #expect(FocusSpy.embedderActive.map(\.browser) == [Self.firstBrowser, next])
        #expect(FocusSpy.embedderActive.map(\.active) == [1, 1])
    }

    /// The pane's page view reports its first responder changes to the tab it shows: embedder-active
    /// once the host detached the page, nothing before.
    @Test func hostModePageViewFirstResponderDrivesEmbedderActiveOnceDetached() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        let page = try #require(host.hostedPageView)

        page.onFocusChange?(true)
        #expect(FocusSpy.embedderActive.isEmpty, "not detached yet")

        tab.hostDetachedPage(browser: Self.firstBrowser)
        page.onFocusChange?(true)
        page.onFocusChange?(false)

        #expect(FocusSpy.embedderActive.map(\.active) == [1, 0])
        #expect(FocusSpy.setFocus.isEmpty)
    }

    @Test func pageViewReportsFirstResponderChanges() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let view = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), inputTarget: .view)
        var changes: [Bool] = []
        view.onFocusChange = { changes.append($0) }
        window.contentView?.addSubview(view)

        #expect(window.makeFirstResponder(view))
        #expect(window.makeFirstResponder(nil))

        #expect(changes == [true, false])
    }

    @Test func aPageWindowTargetNeverTakesFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let view = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), inputTarget: .pageWindow)
        var changes: [Bool] = []
        view.onFocusChange = { changes.append($0) }
        window.contentView?.addSubview(view)

        #expect(!window.makeFirstResponder(view))
        #expect(changes.isEmpty)
    }

    #if DEBUG
    /// The pane's page view asks its pane which page shows: no macOS caret accessory while the
    /// shown tab is a cmux page (``CEFTab/pageThemeSurface``), the system's placement for a web page.
    @Test func hostModePageViewHidesTheCaretAccessoryOnACmuxPage() throws {
        let runtime = try Self.runtime(hostMode: true)
        let (host, tab) = try Self.livePane(runtime)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        let page = try #require(host.hostedPageView)
        #expect(try ChromiumHostPasswordInputTests.accessoryPlacement(of: page) == .unspecified)

        tab.pageThemeSurface = .internalPage
        #expect(try ChromiumHostPasswordInputTests.accessoryPlacement(of: page) == .invisible)

        tab.pageThemeSurface = nil
        #expect(try ChromiumHostPasswordInputTests.accessoryPlacement(of: page) == .unspecified)
    }
    #endif

    // MARK: Fixtures

    private static let firstBrowser: Int32 = 1

    /// A runtime that outlives the test (a pane's scheduled work reads it through an unowned reference).
    private static func runtime(hostMode: Bool) throws -> CEFRuntime {
        FocusSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-tab-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(FocusSpy.symbol), storage: CEFProfileStorage(root: root))
        if hostMode {
            let hostStart = CEFHostStart(supervisor: FocusNoHost(), clock: ContinuousClock())
            hostStart.mapsClientIDs = true
            runtime.hostStart = hostStart
        }
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    private static func pane(_ runtime: CEFRuntime) -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return (host, tab)
    }

    private static func livePane(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab) {
        let (host, tab) = pane(runtime)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })
        runtime.handle(.afterCreated(browser: firstBrowser, request: request, window: 1))
        #expect(tab.browserID == firstBrowser)
        return (host, tab)
    }
}

/// Never attaches: these tests drive panes against the spy shim and never start Chromium.
@MainActor private final class FocusNoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim functions: `set_focus` and `browser_set_embedder_active` record their calls,
/// `fork_api_version` reports 30, every other function does nothing and returns 0.
private nonisolated enum FocusSpy {
    nonisolated(unsafe) static var setFocus: [(browser: Int32, focus: Int32)] = []
    nonisolated(unsafe) static var embedderActive: [(browser: Int32, active: Int32)] = []

    static func reset() {
        setFocus = []
        embedderActive = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { 0 }
        let setFocus: @convention(c) (Int32, Int32) -> Void = { browser, focus in
            FocusSpy.setFocus.append((browser, focus))
        }
        let embedderActive: @convention(c) (Int32, Int32) -> Int32 = { browser, active in
            FocusSpy.embedderActive.append((browser, active))
            return 1
        }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, _, _, _, _, _ in 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 30 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_focus": unsafeBitCast(setFocus, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_embedder_active": unsafeBitCast(embedderActive, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
