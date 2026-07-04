import Foundation

extension PaneMemoryWarning {
    /// Content for the per-pane runaway-memory notification (issue #6313).
    ///
    /// Lives on the warning value (not a static-namespace type) so the
    /// user-facing copy is unit-testable without the notification store,
    /// ghostty, or libproc. The guardrail engine decides *when* a pane is runaway
    /// (edge-trigger + hysteresis) and rate-limits re-notification; this decides
    /// *what* the notification says.
    struct NotificationContent: Equatable {
        let title: String
        let subtitle: String
        let body: String
    }

    /// Bytes → a compact human string (e.g. "14.2 GB"), using the same memory
    /// count style the Task Manager shows so the two surfaces agree.
    static func formattedNotificationMemory(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// The notification cmux posts when this pane first crosses the threshold.
    var notificationContent: NotificationContent {
        let memoryText = Self.formattedNotificationMemory(memoryBytes)
        let title = String(
            localized: "paneMemoryGuardrail.notification.title",
            defaultValue: "Pane is using a lot of memory"
        )

        let subtitle: String
        let command = foregroundCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            paneTitle,
            memoryText
        )

        return NotificationContent(
            title: title,
            subtitle: subtitle,
            body: body
        )
    }
}
