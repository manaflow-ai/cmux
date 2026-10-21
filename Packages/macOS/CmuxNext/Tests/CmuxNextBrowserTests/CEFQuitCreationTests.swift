@testable import CmuxNextBrowser
import Testing

/// Crash on quit, NIGHTLY 1.0.0-nightly.3953614980201 (2026-10-20): AppKit closed the windows
/// for termination after CefShutdown, a window's observer removed a view, a hidden Chromium tab's
/// content view lost its hidden ancestor (`viewDidUnhide`), and the pane created its browser
/// (`cmux_shim_create_window`): CEF aborts creating a browser after shutdown began.
@MainActor @Suite struct CEFQuitCreationTests {
    @Test func noBrowserIsMadeOnceChromiumBeganToStop() {
        #expect(CEFRuntime.acceptsNewBrowsers(state: .ready, stopping: false))
        // Quit closed every browser and waits for Chromium to destroy them (`shutdown`).
        #expect(!CEFRuntime.acceptsNewBrowsers(state: .ready, stopping: true))
        // CefShutdown ran, or quit came while the library was still loading.
        #expect(!CEFRuntime.acceptsNewBrowsers(state: .shutDown, stopping: false))
    }
}
