import Foundation

/// Pure mapping from a runaway-pane warning to its cmux notification content.
///
/// Factored out of `AppDelegate` so the user-facing copy and the per-pane
/// cooldown key are unit-testable without the notification store, ghostty, or
/// libproc. The guardrail engine decides *when* a pane is runaway (edge-trigger
/// + hysteresis); this decides *what* the notification says (issue #6313).
enum PaneMemoryGuardrailNotification {
    /// One notification per runaway episode, deduplicated per pane via `cooldownKey`.
    struct Content: Equatable {
        let title: String
        let subtitle: String
        let body: String
        let cooldownKey: String
    }

    /// Re-notify at most once per this interval per pane, even if the pane keeps
    /// flapping across the clear/threshold band, so a leak can't spam the user.
    static let cooldownInterval: TimeInterval = 300

    /// Stable per-pane cooldown key. Keyed by panel id so a second runaway in a
    /// *different* pane still notifies while one pane is in its cooldown window.
    static func cooldownKey(forPanelId panelId: UUID) -> String {
        "paneMemoryGuardrail.\(panelId.uuidString)"
    }

    static func content(for warning: PaneMemoryWarning) -> Content {
        let memoryText = formattedMemory(warning.memoryBytes)
        let title = String(
            localized: "paneMemoryGuardrail.notification.title",
            defaultValue: "Pane is using a lot of memory"
        )

        let subtitle: String
        let command = warning.foregroundCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command, !command.isEmpty {
            subtitle = String(
                format: String(
                    localized: "paneMemoryGuardrail.notification.subtitle",
                    defaultValue: "%1$@ used by %2$@"
                ),
                memoryText,
                command
            )
        } else {
            subtitle = memoryText
        }

        let body = String(
            format: String(
                localized: "paneMemoryGuardrail.notification.body",
                defaultValue: "The “%1$@” pane’s process tree is using %2$@. A runaway process can make macOS suspend all of cmux. Open the Task Manager (Window menu) to review and stop it."
            ),
            warning.paneTitle,
            memoryText
        )

        return Content(
            title: title,
            subtitle: subtitle,
            body: body,
            cooldownKey: cooldownKey(forPanelId: warning.panelId)
        )
    }

    /// Bytes → a compact human string (e.g. "14.2 GB"), using the same memory
    /// count style the Task Manager shows so the two surfaces agree.
    static func formattedMemory(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
