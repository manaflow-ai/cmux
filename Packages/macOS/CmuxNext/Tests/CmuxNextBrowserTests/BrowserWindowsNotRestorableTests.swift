import AppKit
@testable import CmuxNextBrowser
import Testing

/// AppKit state restoration is off for every cmux window, the Chromium ones too: DevTools and the
/// page info windows never land in Saved Application State.
@MainActor struct BrowserWindowsNotRestorableTests {
    @Test func theDevToolsWindowIsNotRestorable() {
        _ = NSApplication.shared
        let window = CEFDevToolsWindow(frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        defer { window.close() }
        #expect(!window.isRestorable)
    }

    @Test func aPageInfoWindowIsNotRestorable() {
        _ = NSApplication.shared
        let window = PageInfoWindow(title: "Info", size: CGSize(width: 300, height: 200))
        defer { window.close() }
        #expect(!window.isRestorable)
    }
}
