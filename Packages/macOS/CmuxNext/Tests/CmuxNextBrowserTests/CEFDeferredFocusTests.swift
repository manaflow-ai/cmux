import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Cmd-N in NIGHTLY 1.0.0-nightly.3968001295301 sometimes left the new workspace's New Tab field
/// without the keyboard: the page (a prewarmed spare whose browser already existed) asked for focus
/// a moment before its Chromium window showed, `setFocused(true)` refused a hidden page, and only a
/// browser's creation (`attach`) replayed that ask. The page then showed with no focus, and the
/// focus applier, which had already asked, never asked again.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDeferredFocusTests {
    /// A page with its browser asks for focus before its view is in a window; it gets it once it shows.
    @Test func focusAskedBeforeThePageShowsIsGrantedWhenItShows() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 7)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty, "a page that does not show takes no focus")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        #expect(FocusSpyShim.granted == [7])
    }

    /// A shown page the content lifecycle hid (its first paint not there yet) asks for focus; it gets
    /// it when the lifecycle shows it again.
    @Test func focusAskedWhileTheLifecycleHidThePageIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        tab.setContentVisible(false)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty)

        tab.setContentVisible(true)
        #expect(FocusSpyShim.granted == [8])
    }

    /// An ask taken back (focus moved on) before the page showed is not granted later.
    @Test func focusTakenBackBeforeThePageShowsIsNotGranted() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 9)

        tab.setFocused(true)
        tab.setFocused(false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        #expect(FocusSpyShim.granted.isEmpty)
    }

    /// NIGHTLY 1.0.0-nightly.4093446036501 beachballed for good: a workspace switch hid an ancestor of
    /// the focused page's view. Chromium ordered the page window out inside AppKit's hide walk, before
    /// the page's own `viewDidHide`; the cmux window took the keys, the focus applier asked again, and
    /// the grant showed the page window again, around and around in one main-thread turn. A page
    /// under a hidden ancestor takes no focus; it gets it when its view shows again.
    @Test func focusAskedWhileAnAncestorHidesIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 10)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Hidden first in AppKit's walk, as Chromium's view was: it asks for focus mid-hide.
        let chromium = HideSpyView(frame: workspace.bounds)
        workspace.addSubview(chromium)
        workspace.addSubview(tab.contentView)
        try #require(window.contentView).addSubview(workspace)
        FocusSpyShim.granted = []
        chromium.onHide = { tab.setFocused(true) }

        workspace.isHidden = true
        #expect(FocusSpyShim.granted.isEmpty, "a page under a hidden ancestor was given focus: \(FocusSpyShim.granted)")

        chromium.onHide = nil
        workspace.isHidden = false
        #expect(FocusSpyShim.granted == [10])
    }

    /// The same ask from inside the page's own view (where Chromium's view sits), whichever order
    /// AppKit tells a view and its subviews that an ancestor hid.
    @Test func focusAskedFromInsideThePageWhileAnAncestorHidesIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 11)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        try #require(window.contentView).addSubview(workspace)
        workspace.addSubview(tab.contentView)
        let chromium = HideSpyView(frame: tab.contentView.bounds)
        tab.contentView.addSubview(chromium)
        FocusSpyShim.granted = []
        chromium.onHide = { tab.setFocused(true) }

        workspace.isHidden = true
        #expect(FocusSpyShim.granted.isEmpty, "a page under a hidden ancestor was given focus: \(FocusSpyShim.granted)")

        chromium.onHide = nil
        workspace.isHidden = false
        #expect(FocusSpyShim.granted == [11])
    }

    /// browser-click-then-type (STATUS 7374): the grant gave the page focus but its page window did not become key
    /// (a fresh launch, a page loaded from the address bar). The cmux window kept the keys with itself as first
    /// responder, and every plain key typed for the page reached no view. The page window takes the keys from the cmux
    /// window that shows it: one key change.
    @Test func aGrantThatMovesNoKeyHandsTheKeysFromTheCmuxWindowToThePageWindow() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        let page = pageWindow(over: tab, in: window)
        defer { page.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam

        tab.setFocused(true)
        #expect(FocusSpyShim.granted == [12])
        #expect(keys.key === page, "the page has focus but the cmux window kept the keys")
        #expect(keys.made.count == 1, "one focus request made \(keys.made.count) key changes")
    }

    /// The same hand-over for a grant that waited for the page to show (``CEFTab/grantPendingFocusIfShown()``): a
    /// hidden page takes neither focus nor the keys, and gets both when it shows.
    @Test func aDelayedGrantThatMovesNoKeyAlsoHandsTheKeysToThePageWindow() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 13)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        let page = pageWindow(over: tab, in: window)
        defer { page.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam
        tab.setContentVisible(false)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty)
        #expect(keys.made.isEmpty, "a hidden page took the keys")

        tab.setContentVisible(true)
        #expect(FocusSpyShim.granted == [13])
        #expect(keys.key === page, "the delayed grant left the keys on the cmux window")
        #expect(keys.made.count == 1)
    }

    /// A grant whose page window became key (CEF moved the keys itself) gets no second key change; an inactive app
    /// (no key window) and another window that has the keys keep them.
    @Test func aGrantTakesNoKeysWhenCEFMovedThemOrAnotherWindowOrNoneHasThem() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 14)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        let page = pageWindow(over: tab, in: window)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        defer { page.closeAfterTest(); other.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam

        FocusSpyShim.onGrant = { MainActor.assumeIsolated { keys.key = page } }
        defer { FocusSpyShim.onGrant = nil }
        tab.setFocused(true)
        #expect(keys.made.isEmpty, "CEF moved the keys and the grant moved them again")

        FocusSpyShim.onGrant = nil
        for key in [nil, other] {
            tab.setFocused(false)
            keys.key = key
            tab.setFocused(true)
            #expect(keys.key === key, "the page took the keys from \(key.map { String(describing: $0) } ?? "an inactive app")")
        }
        #expect(keys.made.isEmpty)
    }

    /// A Chromium page window over `tab`'s view, a child of `window`, as the fork places it.
    private func pageWindow(over tab: CEFTab, in window: NSWindow) -> NSWindow {
        let frame = window.convertToScreen(tab.host.hostView.convert(tab.host.hostView.bounds, to: nil))
        let page = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        page.setFrame(frame, display: false)
        window.addChildWindow(page, ordered: .above)
        return page
    }

    /// A tab whose browser Chromium made (`afterCreated`), its view in no window yet.
    private func createdTab(_ runtime: CEFRuntime, browser: Int32) throws -> (CEFTab, CEFPaneHost) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        #expect(tab.browserID == browser)
        FocusSpyShim.granted = []
        return (tab, host)
    }
}

/// The app's key window in a test: every change a grant makes is recorded.
@MainActor private final class KeyRecorder {
    var key: NSWindow?
    private(set) var made: [NSWindow] = []

    init(key: NSWindow?) { self.key = key }

    var seam: CEFKeyWindows {
        CEFKeyWindows(keyWindow: { [unowned self] in key }, makeKey: { [unowned self] window in
            key = window
            made.append(window)
        })
    }
}

/// A view that runs `onHide` when an ancestor hides it.
private final class HideSpyView: NSView {
    var onHide: (() -> Void)?

    override func viewDidHide() {
        super.viewDidHide()
        onHide?()
    }
}

/// Stand-in shim functions: `cmux_shim_set_focus` records the browsers given focus,
/// `cmux_shim_create_window` reports the browser started; every other function does nothing.
private nonisolated enum FocusSpyShim {
    nonisolated(unsafe) static var granted: [Int32] = []
    /// Runs inside a grant (CEF's SetFocus), as a page window becoming key would.
    nonisolated(unsafe) static var onGrant: (() -> Void)?
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    @MainActor static func runtime() throws -> (CEFRuntime, URL) {
        granted = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        return (runtime, root)
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let setFocus: @convention(c) (Int32, Int32) -> Void = { browser, focused in
            if focused == 1 { FocusSpyShim.granted.append(browser); FocusSpyShim.onGrant?() }
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_focus": unsafeBitCast(setFocus, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
