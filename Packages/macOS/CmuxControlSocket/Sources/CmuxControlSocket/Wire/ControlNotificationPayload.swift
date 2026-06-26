internal import Foundation

/// The parsed `<title>|<subtitle>|<body>` payload shared by the v1 notify
/// commands (`notify`, `notify_surface`, `notify_target`, `notify_target_async`).
///
/// A pure, `Sendable` value produced by ``parse(_:)`` from the raw payload
/// string. The split is byte-faithful to the legacy god-file
/// `parseNotificationPayload(_:)`: the trimmed payload is split on `|` into at
/// most three fields (keeping empty subsequences), each field is whitespace
/// trimmed, an empty or whitespace-only payload yields the default
/// `("Notification", "", "")`, and an empty title falls back to `"Notification"`.
/// The two-field case maps the second field to the body (leaving the subtitle
/// empty), exactly as the legacy code did. The app-side notify witnesses consume
/// these fields to deliver or enqueue the notification.
public struct ControlNotificationPayload: Sendable, Equatable {
    /// The notification title, never empty (defaults to `"Notification"`).
    public let title: String
    /// The notification subtitle, empty when not supplied.
    public let subtitle: String
    /// The notification body, empty when not supplied.
    public let body: String

    /// Creates a notification payload value.
    ///
    /// - Parameters:
    ///   - title: The notification title.
    ///   - subtitle: The notification subtitle.
    ///   - body: The notification body.
    public init(title: String, subtitle: String, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// Parses the raw `<title>|<subtitle>|<body>` payload string.
    ///
    /// Byte-faithful to the legacy `parseNotificationPayload(_:)`: the payload is
    /// whitespace trimmed; an empty result yields `("Notification", "", "")`;
    /// otherwise it is split on `|` into at most three parts (empty subsequences
    /// kept) and each part is whitespace trimmed. The subtitle is only populated
    /// when three or more parts are present; with exactly two parts the second
    /// part becomes the body. An empty title falls back to `"Notification"`.
    ///
    /// - Parameter args: The raw payload substring following the notify command.
    /// - Returns: The parsed payload fields.
    public static func parse(_ args: String) -> ControlNotificationPayload {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ControlNotificationPayload(title: "Notification", subtitle: "", body: "") }
        let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return ControlNotificationPayload(
            title: title.isEmpty ? "Notification" : title,
            subtitle: subtitle,
            body: body
        )
    }
}
