import Foundation

/// The reason a new terminal's tab or pane went away again (`terminal-async-start-v1`).
nonisolated extension RefusalStrings {
    /// A terminal whose shell the daemon could not start after its tab showed
    /// (`terminal-start-failed`); `reason` is the daemon's error, when it gave one.
    public static func terminalDidNotStart(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return text("handlers.refusal.terminalDidNotStart", "The terminal did not start.") }
        return format("handlers.refusal.terminalDidNotStartBecause", "The terminal did not start: %@", reason)
    }
}
