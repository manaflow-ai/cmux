/// Lets one Chromium focus or key-window change run at a time.
///
/// Chromium's `SetFocus` makes its page window key, which posts
/// `didBecomeKey`; a pane answers by making its own window key, whose
/// `becomeKey` focuses a page again. Without a gate that ping-pong recurses
/// until the main thread's stack runs out.
///
/// Every `SetFocus` goes through ``runOrDefer(_:)`` and a pane's key reclaim
/// through ``run(_:)``. A reclaim started inside a gated change is dropped: the
/// outer change already moves focus where cmux wants. A focus request started
/// inside one is kept (the latest wins) and runs once after the outer change,
/// so a page cmux asked to focus meanwhile still gets the keys; anything that
/// replay starts is dropped, which bounds the chain.
///
/// A class, not a struct: a re-entrant call on a mutating struct method would
/// trap on Swift's exclusive-access check instead of being dropped.
@MainActor
public final class ChromiumFocusReentrancyGate {
    /// The gate every Chromium page and pane shares: the cycle crosses
    /// windows, so a per-page gate would not see it.
    public static let shared = ChromiumFocusReentrancyGate()

    public private(set) var isRunning = false
    private var deferred: (() -> Void)?

    public init() {}

    /// Runs `body` unless a gated body is already running; returns whether it
    /// ran.
    @discardableResult
    public func run(_ body: () -> Void) -> Bool {
        guard !isRunning else { return false }
        enter(body)
        return true
    }

    /// Runs `body` now, or once the running gated body returns (replacing an
    /// earlier deferred request).
    public func runOrDefer(_ body: @escaping () -> Void) {
        guard !isRunning else {
            deferred = body
            return
        }
        enter(body)
    }

    private func enter(_ body: () -> Void) {
        isRunning = true
        defer {
            deferred = nil
            isRunning = false
        }
        body()
        if let replay = deferred {
            deferred = nil
            replay()
        }
    }
}
