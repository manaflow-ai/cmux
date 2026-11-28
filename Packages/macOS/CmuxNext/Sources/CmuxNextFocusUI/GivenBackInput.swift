public import Foundation

/// Keys the daemon gave back from a terminal creation that did not take them (cx-wb5.78,
/// `terminal-input-unclaimed`), held until a terminal can take them: the focused one that is not
/// being created itself (a give-back can arrive while the failed creation's view still has focus).
/// Keys held longer than `limit` are dropped, never typed: much later they would land in a
/// terminal the user did not type them for (and may hold a Return).
@MainActor
public final class GivenBackInput {
    /// The app's one holder.
    public static let shared = GivenBackInput()
    private var bytes = Data()
    private var since: ContinuousClock.Instant?
    private let limit: Duration
    private let now: () -> ContinuousClock.Instant

    public init(limit: Duration = .seconds(3), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.limit = limit
        self.now = now
    }

    /// Adds `more`, then hands everything held to `target`, when there is one.
    public func deliver(adding more: Data = Data(), to target: (@MainActor (Data) -> Void)?) {
        if let since, now() - since > limit {
            bytes = Data()
            self.since = nil
        }
        if !more.isEmpty {
            if bytes.isEmpty { since = now() }
            bytes.append(more)
        }
        guard !bytes.isEmpty, let target else { return }
        target(bytes)
        bytes = Data()
        since = nil
    }
}
