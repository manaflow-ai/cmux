/// Decides which browser failures are sent, so a crash loop (668 renderer
/// ends in one session) sends a few events with a count, not one per end.
///
/// Counts each failure key (``CmuxNextCompat/BrowserEngineFailure/dedupeKey``:
/// kind, termination, code and host) for the launch and admits the 1st, 10th,
/// 100th, 1000th... of each. At most ``maxKeys`` keys are counted; a new key
/// after that is never sent. A pure value: the caller holds it under its own
/// lock, so tests drive it directly.
public nonisolated struct BrowserFailureThrottle: Sendable, Equatable {
    /// The most distinct keys counted in one launch (default 50).
    public let maxKeys: Int
    private var counts: [String: Int] = [:]

    /// - Parameter maxKeys: The most distinct keys counted (at least 1).
    public init(maxKeys: Int = 50) {
        self.maxKeys = max(1, maxKeys)
    }

    /// Counts one failure with `key`.
    /// - Parameter key: The failure's dedupe key.
    /// - Returns: The key's count so far when this one is sent (1, 10, 100...), else nil.
    public mutating func admit(_ key: String) -> Int? {
        if counts[key] == nil, counts.count >= maxKeys { return nil }
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        return Self.isSentCount(count) ? count : nil
    }

    /// Whether `count` is 1 or a power of ten.
    static func isSentCount(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        var rest = count
        while rest % 10 == 0 { rest /= 10 }
        return rest == 1
    }
}
