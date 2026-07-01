import Foundation

/// A coding-agent notification, classified for hibernation purposes.
///
/// `isBlockingPrompt` is the single source of truth for "should this notification
/// keep the pane live", shared by the dedicated Claude hook lane and the generic
/// agent-hook lane. The hibernation lifecycle has one authoritative idle source (the
/// Stop hook); a notification may only *assert* `.needsInput` (never force `.idle`
/// from ambiguous prose) and only when `isBlockingPrompt` is true. Everything else
/// leaves the lifecycle untouched so a finished agent stays hibernation-eligible
/// across every agent kind.
///
/// Modeled as an instantiated value (rather than a static helper) so it owns its
/// inputs, and lives in this package (rather than the CLI executable target) so it is
/// unit testable via `swift test` without launching the app.
public struct AgentNotification {
    /// The structured event/reason field (e.g. `permission_prompt`, `error`).
    public let signal: String
    /// The free-text notification message.
    public let message: String

    /// Create a notification from its structured signal/reason field and free-text message.
    public init(signal: String, message: String) {
        self.signal = signal
        self.message = message
    }

    /// Whether this notification describes a genuinely blocking prompt (the user must
    /// act now) rather than a routine waiting/idle reminder or a completion.
    ///
    /// Blocking == a permission/approval request, an error, or a genuine question the
    /// user must answer. A routine "waiting for input" / "idle" reminder is NOT blocking
    /// (it fires after every turn end, so blocking on it would clobber the Stop hook's
    /// `.idle` and the pane would never hibernate). The genuine-question rule mirrors the
    /// CLI notification classifier's question branch (`containsWaitingCue`), so a prompt
    /// that surfaces only through a Notification hook (agents without a dedicated
    /// needs-input path) still keeps its pane live while the user answers.
    public var isBlockingPrompt: Bool {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval")
            || lower.contains("permission_prompt")
            || lower.contains("error") || lower.contains("failed") || lower.contains("failure")
            || lower.contains("exception") {
            return true
        }
        return agentNotificationContainsGenuineQuestionCue(lower)
    }
}

/// A genuine prompt the user must answer, as opposed to a routine "waiting for input"
/// nudge. Detected from high-confidence signals only: a direct interrogative (contains
/// `?`), or the literal `question` token paired with an interaction word.
///
/// Deliberately NOT keyed on bare verbs like `confirm`/`choose`/`continue`/`proceed`:
/// those collide with routine agent chatter ("continue when ready", "proceed to the
/// next step"), and blocking on them would clobber the Stop hook's `.idle` so the pane
/// never hibernates — the exact bug this lane exists to prevent. Routine idle/waiting
/// reminders never carry a `?`, so they stay non-blocking. A genuine but
/// punctuation-free imperative ("Choose an option") is intentionally left to the
/// authoritative structured signal (`notification_type`), not this free-text heuristic.
/// Mirrors the CLI classifier's `containsWaitingCue` so the blocking decision and the
/// `.needsInput` classification stay in lockstep.
private func agentNotificationContainsGenuineQuestionCue(_ lowercasedText: String) -> Bool {
    if lowercasedText.contains("?") { return true }
    let tokens = lowercasedText.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    guard tokens.contains("question") else { return false }
    let interactionCues: Set<String> = [
        "answer", "respond", "response", "reply", "choose", "confirm", "continue",
    ]
    return tokens.contains { interactionCues.contains($0) }
}
