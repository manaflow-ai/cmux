/// Quit ordering for a live Chromium engine: close every browser, wait for
/// every OnBeforeClose, keep pumping until the fork's window count is 0, then
/// call CefShutdown. Calling CefShutdown while a Chromium browser still exists
/// crashes (TabDragServiceImpl in the cmux CEF fork). Ported from cmux Next's
/// `CEFShutdownSequence`.
///
/// The app delegate's terminate path drives this: it answers
/// `.terminateLater`, runs the sequence while the message pump keeps going,
/// and replies once `phase == .readyToShutdown` and CefShutdown returned. A
/// WebKit-only session never starts it.
public struct ChromiumShutdownSequence: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case running
        case closingBrowsers
        case waitingForWindows
        case readyToShutdown
    }

    public private(set) var phase: Phase = .running
    private var liveBrowsers: Int
    /// -1 when the engine has no window count (stock CEF): skip that wait.
    private var windows: Int

    public init(liveBrowsers: Int, windows: Int) {
        self.liveBrowsers = liveBrowsers
        self.windows = windows
    }

    /// Starts the sequence. The caller closes all browsers.
    public mutating func begin() {
        guard phase == .running else { return }
        phase = .closingBrowsers
        advance()
    }

    public mutating func browserClosed(remaining: Int) {
        liveBrowsers = remaining
        advance()
    }

    public mutating func windowDestroyed(remaining: Int) {
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
