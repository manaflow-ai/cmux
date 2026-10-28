import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Cmd-N in NIGHTLY 1.0.0-nightly.3968001295301 sometimes left the new workspace's New Tab field
/// without the keyboard: the page (a prewarmed spare whose browser already existed) asked for focus
/// a moment before its Chromium window showed, `setFocused(true)` refused a hidden page, and only a
/// browser's creation (`attach`) replayed that ask. The page then showed with no focus, and the
/// focus applier, which had already asked, never asked again.
@MainActor @Suite(.serialized) struct CEFDeferredFocusTests {
    /// A page with its browser asks for focus before its view is in a window; it gets it once it shows.
    @Test func focusAskedBeforeThePageShowsIsGrantedWhenItShows() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 7)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty, "a page that does not show takes no focus")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
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
        try #require(window.contentView).addSubview(tab.contentView)
        #expect(FocusSpyShim.granted.isEmpty)
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
