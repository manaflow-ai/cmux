import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// BROWSER VIDEO F1 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz films on feat 0d19fe6, 2026-11-02): in the light
/// theme, docked DevTools showed a DARK block (#1D1D1D) for 10-12 refreshes before its frontend drew, in every open.
/// The DevTools browser took no background of its own: Chromium painted it with CefSettings.background_color from CEF
/// start (the theme the app launched in), never the pane's theme now. Every other browser of a pane starts on the
/// pane's theme color (`CEFPaneHost`: `PageBackground.themeARGB(in: hostView)`); DevTools now does too.
@MainActor @Suite(.serialized) struct CEFDevToolsBackgroundTests {
    @Test func devToolsStartsOnThePanesThemeColorNotTheColorCEFStartedWith() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        // Chromium asks where DevTools goes (OnBeforeDevToolsPopup -> DEVTOOLS_WILL_OPEN), inside the show command.
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        let host = try #require(tab.devToolsController.views?.host)
        let want = PageBackground.themeARGB(in: host)
        let backgrounds = ShimLog.calls.filter { $0.hasPrefix("devtools-background") }
        #expect(backgrounds == ["devtools-background \(Rig.browser) \(want)"], "DevTools takes the pane's theme color")
        let placement = try #require(ShimLog.calls.firstIndex { $0.hasPrefix("devtools-placement") })
        let background = try #require(ShimLog.calls.firstIndex { $0.hasPrefix("devtools-background") })
        #expect(background < placement, "the color is set before Chromium reads the placement")
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 13
        let runtime: CEFRuntime
        let root: URL
        /// The pane's window: DevTools docks only in a tab shown in a window (`CEFDevToolsController.willOpen`).
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)

        init() throws {
            ShimLog.calls = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-bg-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
        }

        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            tab.container.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(tab.container)
            ShimLog.calls = []
            return tab
        }

        func close() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The DevTools placement calls the shim got, in order (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var calls: [String] = []

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let placement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void = { browser, _, _, _, _, _ in
            ShimLog.calls.append("devtools-placement \(browser)")
        }
        let background: @convention(c) (Int32, UInt32) -> Void = { browser, argb in
            ShimLog.calls.append("devtools-background \(browser) \(argb)")
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_set_placement": unsafeBitCast(placement, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_set_background": unsafeBitCast(background, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
