public import Foundation

/// Pure decision logic for client-side sessionization.
///
/// A "session" is a UUID minted on cold start and on any foreground that follows
/// more than ``inactivityWindow`` of background time. The window defaults to 30
/// minutes to match PostHog's default server-side session window, so the client
/// `session_id` and PostHog's `$session_id` agree. This type holds no mutable
/// state and does no persistence — the caller owns the persisted last-background
/// timestamp and current session id and feeds them in. That keeps the decision a
/// pure, exhaustively testable transformation.
///
/// ```swift
/// let sessionizer = AnalyticsSessionizer()
/// let decision = sessionizer.resolveForeground(
///     now: now,
///     lastBackgroundedAt: stored.lastBackground,
///     currentSessionID: stored.sessionID
/// )
/// if decision.startedNewSession { analytics.capture("ios_session_started", …) }
/// ```
public struct AnalyticsSessionizer: Sendable {
    /// The maximum background gap that still continues the same session.
    public let inactivityWindow: TimeInterval

    /// Creates a sessionizer.
    ///
    /// - Parameter inactivityWindow: How long the app may stay backgrounded
    ///   before the next foreground starts a new session. Defaults to 30 minutes
    ///   (1800s) to match PostHog's server window.
    public init(inactivityWindow: TimeInterval = 30 * 60) {
        self.inactivityWindow = inactivityWindow
    }

    /// The outcome of resolving a foreground (cold start or warm resume).
    public struct Decision: Sendable, Equatable {
        /// The session id the app should use from now on.
        public let sessionID: UUID
        /// Whether this foreground began a brand-new session.
        public let startedNewSession: Bool
        /// The gap since the app was last backgrounded, or `nil` on cold start.
        public let secondsSinceBackgrounded: TimeInterval?

        /// Creates a decision.
        public init(sessionID: UUID, startedNewSession: Bool, secondsSinceBackgrounded: TimeInterval?) {
            self.sessionID = sessionID
            self.startedNewSession = startedNewSession
            self.secondsSinceBackgrounded = secondsSinceBackgrounded
        }
    }

    /// Resolves the session for a foreground transition.
    ///
    /// Starts a new session when there is no current session (cold start), when
    /// there is no recorded last-background timestamp, or when the gap since the
    /// last background exceeds ``inactivityWindow``. Otherwise the existing
    /// session continues.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - lastBackgroundedAt: When the app last entered the background, or `nil`
    ///     if it has not backgrounded since launch (cold start).
    ///   - currentSessionID: The persisted current session id, or `nil` if none.
    ///   - newSessionID: The id to assign when a new session starts. Defaults to
    ///     a fresh `UUID`; injectable for deterministic tests.
    /// - Returns: The resolved ``Decision``.
    public func resolveForeground(
        now: Date,
        lastBackgroundedAt: Date?,
        currentSessionID: UUID?,
        newSessionID: UUID = UUID()
    ) -> Decision {
        guard let currentSessionID, let lastBackgroundedAt else {
            return Decision(sessionID: newSessionID, startedNewSession: true, secondsSinceBackgrounded: nil)
        }
        let gap = now.timeIntervalSince(lastBackgroundedAt)
        if gap > inactivityWindow {
            return Decision(sessionID: newSessionID, startedNewSession: true, secondsSinceBackgrounded: gap)
        }
        return Decision(sessionID: currentSessionID, startedNewSession: false, secondsSinceBackgrounded: gap)
    }
}
