public import Foundation

/// Persists the sessionization inputs across launches: the current session id and
/// the last time the app entered the background.
///
/// `MobileShellComposite`/the app shell reads these on a foreground, feeds them
/// to ``AnalyticsSessionizer`` to decide whether to start a new session, then
/// writes back the resolved session id; on background it records the timestamp.
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`. Returning value types keeps the read path pure.
public struct AnalyticsSessionStore: Sendable {
    private static let sessionIDKey = "dev.cmux.analytics.sessionID"
    private static let lastBackgroundedKey = "dev.cmux.analytics.lastBackgroundedAt"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a session store.
    /// - Parameter defaults: The persistence store. Inject a suite-scoped store
    ///   in tests; the app uses `.standard`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The persisted current session id, or `nil` if none has been recorded.
    public var currentSessionID: UUID? {
        guard let raw = defaults.string(forKey: Self.sessionIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// The persisted last-backgrounded timestamp, or `nil` if the app has not
    /// backgrounded since install.
    public var lastBackgroundedAt: Date? {
        let seconds = defaults.double(forKey: Self.lastBackgroundedKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Persists the resolved current session id.
    /// - Parameter id: The session id to store.
    public func setCurrentSessionID(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Self.sessionIDKey)
    }

    /// Records when the app entered the background, for the next foreground's
    /// inactivity-gap calculation.
    /// - Parameter date: The background timestamp.
    public func recordBackgrounded(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastBackgroundedKey)
    }
}
