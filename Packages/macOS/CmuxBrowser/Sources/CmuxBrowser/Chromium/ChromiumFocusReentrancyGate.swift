/// Lets one Chromium focus or key-window change run at a time.
///
/// Chromium's `SetFocus` makes its page window key, which posts
/// `didBecomeKey`; the pane answers by making its own window key, whose
/// `becomeKey` focuses the page again. Without a gate that ping-pong recurses
/// until the main thread's stack runs out. A body started while another is
/// running is dropped: the outer change already moves focus where cmux wants.
///
/// A class, not a struct: a re-entrant call on a mutating struct method would
/// trap on Swift's exclusive-access check instead of being dropped.
@MainActor
public final class ChromiumFocusReentrancyGate {
    /// The gate every Chromium page and pane shares: the cycle crosses
    /// windows, so a per-page gate would not see it.
    public static let shared = ChromiumFocusReentrancyGate()

    public private(set) var isRunning = false

    public init() {}

    /// Runs `body` unless a gated body is already running; returns whether it
    /// ran.
    @discardableResult
    public func run(_ body: () -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        body()
        return true
    }
}
