public import Foundation

/// Keys the daemon gave back from a terminal creation that did not take them (cx-wb5.78,
/// `terminal-input-unclaimed`), held until a terminal of the window they were typed in can take
/// them: its focused one that is not being created itself (a give-back can arrive while the failed
/// creation's view still has focus). Never a terminal of another window (Lawrence 2026-10-23:
/// "i type in one window of cmux, but the text appears in another window"); keys of no known
/// window are dropped. Keys held longer than `limit` are dropped, never typed: much later they
/// would land in a terminal the user did not type them for (and may hold a Return).
@MainActor
public final class GivenBackInput {
    /// The app's one holder.
    public static let shared = GivenBackInput()
    private var bytes = Data()
    /// The window the held keys were typed in.
    private var window: String?
    private var since: ContinuousClock.Instant?
    private let limit: Duration
    private let now: () -> ContinuousClock.Instant

    public init(limit: Duration = .seconds(3), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.limit = limit
        self.now = now
    }

    /// Adds `more`, typed in `window`, then hands everything held to `target`, a terminal in
    /// `window`, when there is one and the held keys were typed in that window.
    ///
    /// - Parameters:
    ///   - more: Keys to hold, typed in `window`; with no `window` they are dropped.
    ///   - window: The window `more` was typed in, and the window `target` is in.
    ///   - target: Writes to the focused terminal of `window`; nil while there is none.
    public func deliver(adding more: Data = Data(), window: String?, to target: (@MainActor (Data) -> Void)?) {
        if let since, now() - since > limit { drop() }
        if !more.isEmpty, let window {
            if self.window != window { drop() }
            if bytes.isEmpty { since = now() }
            self.window = window
            bytes.append(more)
        }
        guard !bytes.isEmpty, let window, window == self.window, let target else { return }
        target(bytes)
        drop()
    }

    private func drop() {
        bytes = Data()
        window = nil
        since = nil
    }
}
