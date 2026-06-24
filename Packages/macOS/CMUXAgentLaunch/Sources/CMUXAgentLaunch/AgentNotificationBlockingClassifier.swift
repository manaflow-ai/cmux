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

    public init(signal: String, message: String) {
        self.signal = signal
        self.message = message
    }

    /// Whether this notification describes a genuinely blocking prompt (the user must
    /// act now) rather than a routine waiting/idle reminder or a completion.
    public var isBlockingPrompt: Bool {
        let lower = "\(signal) \(message)".lowercased()
        return lower.contains("permission") || lower.contains("approve") || lower.contains("approval")
            || lower.contains("permission_prompt")
            || lower.contains("error") || lower.contains("failed") || lower.contains("failure")
            || lower.contains("exception")
    }
}
