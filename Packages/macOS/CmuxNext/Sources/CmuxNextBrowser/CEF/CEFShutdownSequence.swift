import Foundation

/// Quit ordering for a live CEF (fork API v2, browser.md "Fork clip patches"):
/// close every browser, wait for every OnBeforeClose, keep pumping until
/// `cmux_browser_window_count()` is 0, then CefShutdown. Calling CefShutdown
/// while a Chromium Browser still exists crashes in TabDragServiceImpl.
nonisolated struct CEFShutdownSequence: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        case closingBrowsers
        case waitingForWindows
        case readyToShutdown
    }

    private(set) var phase: Phase = .running
    private var liveBrowsers: Int
    /// -1 when the fork API has no window count (stock CEF): skip that wait.
    private var windows: Int

    init(liveBrowsers: Int, windows: Int) {
        self.liveBrowsers = liveBrowsers
        self.windows = windows
    }

    /// Starts the sequence. The caller closes all browsers.
    mutating func begin() {
        guard phase == .running else { return }
        phase = .closingBrowsers
        advance()
    }

    mutating func browserClosed(remaining: Int) {
        liveBrowsers = remaining
        advance()
    }

    mutating func windowDestroyed(remaining: Int) {
        windows = remaining
        advance()
    }

    private mutating func advance() {
        if phase == .closingBrowsers, liveBrowsers <= 0 {
            phase = .waitingForWindows
        }
        if phase == .waitingForWindows, windows <= 0 {
            phase = .readyToShutdown
        }
    }
}
