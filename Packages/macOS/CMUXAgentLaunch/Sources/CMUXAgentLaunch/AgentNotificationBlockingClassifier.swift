import Foundation

/// Whether a notification's text describes a genuinely blocking prompt (the user
/// must act now) rather than a routine waiting/idle reminder or a completion.
///
/// Single source of truth for "should this notification keep the pane live",
/// shared by the dedicated Claude hook lane and the generic agent-hook lane. The
/// hibernation lifecycle has one authoritative idle source (the Stop hook); a
/// notification may only *assert* `.needsInput` (never force `.idle` from ambiguous
/// prose) and only when this returns true. Everything else leaves the lifecycle
/// untouched so a finished agent stays hibernation-eligible across every agent type.
///
/// Lives in this package (rather than the CLI executable target) so it is unit
/// testable via `swift test` without launching the app: the hibernation
/// correctness of every coding-agent kind funnels through this one decision.
public func agentNotificationIsBlockingPrompt(signal: String, message: String) -> Bool {
    let lower = "\(signal) \(message)".lowercased()
    return lower.contains("permission") || lower.contains("approve") || lower.contains("approval")
        || lower.contains("permission_prompt")
        || lower.contains("error") || lower.contains("failed") || lower.contains("failure")
        || lower.contains("exception")
}
