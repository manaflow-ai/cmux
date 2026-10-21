import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Crash on quit, NIGHTLY 1.0.0-nightly.3953614980201 (2026-10-20): AppKit closed the windows
/// for termination after CefShutdown, a window's observer removed a view, a hidden Chromium tab's
/// content view lost its hidden ancestor (`viewDidUnhide`), and the pane created its browser
/// (`cmux_shim_create_window`): CEF aborts creating a browser after shutdown began.
@MainActor @Suite(.serialized) struct CEFQuitCreationTests {
    @Test func noBrowserIsMadeOnceChromiumBeganToStop() {
        #expect(CEFRuntime.acceptsNewBrowsers(state: .ready, stopping: false))
        // Quit closed every browser and waits for Chromium to destroy them (`shutdown`).
        #expect(!CEFRuntime.acceptsNewBrowsers(state: .ready, stopping: true))
        // CefShutdown ran, or quit came while the library was still loading.
        #expect(!CEFRuntime.acceptsNewBrowsers(state: .shutDown, stopping: false))
    }

    /// The crash's path, against a spy shim: a parked tab never shown unhides in its window
    /// (`viewDidUnhide`), so the tab appears and its pane makes its browser
    /// (`CEFTab.contentDidAppear`, `CEFPaneHost.present`, `ensureCreated`).
    @Test func aParkedTabUnhiddenAfterChromiumStoppedMakesNoBrowser() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try SpyShim.library(), storage: CEFProfileStorage(root: root))
        // Chromium running: the tab gets its browser.
        #expect(try unhideParkedTab(runtime) == 1)
        runtime.state = .shutDown
        #expect(try unhideParkedTab(runtime) == 0)
    }

    /// Calls of `cmux_shim_create_window` while a parked Chromium tab of a new pane unhides.
    private func unhideParkedTab(_ runtime: CEFRuntime) throws -> Int {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        let content = try #require(window.contentView)
        let parked = NSView(frame: content.bounds)
        parked.isHidden = true
        content.addSubview(parked)
        parked.addSubview(tab.contentView)
        let before = SpyShim.createWindowCalls
        parked.isHidden = false
        return SpyShim.createWindowCalls - before
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` counts its calls and reports the browser
/// started; every other function does nothing and returns 0.
private nonisolated enum SpyShim {
    nonisolated(unsafe) static var createWindowCalls = 0

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            SpyShim.createWindowCalls += 1
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            if name == "cmux_shim_create_window" { return unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) }
            return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
