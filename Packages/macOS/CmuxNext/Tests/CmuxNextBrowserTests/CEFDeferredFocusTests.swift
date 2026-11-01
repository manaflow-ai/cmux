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
        let setFocus: @convention(c) (Int32, Int32) -> Void = { browser, focused in if focused == 1 { FocusSpyShim.granted.append(browser) } }
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
