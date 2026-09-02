import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

/// A compact, immutable projection of the four facts a user scans before
/// opening, plus the row's precomputed accessibility details. Built once per
/// item on the projection's background rebuild so row bodies do no string
/// work during scroll.
///
/// The workspace title is the row's headline: agents reuse one generic
/// notification title ("Claude Code") across every workspace, so the workspace
/// is what distinguishes rows at a glance. The notification title demotes to
/// the provenance line and is dropped entirely when it repeats the headline.
struct NotificationFeedRowPresentation: Equatable, Sendable {
    /// The workspace title, falling back to the notification title when the
    /// item carries no workspace, then to the localized unknown label.
    let headline: String
    /// The notifying agent or app ("Claude Code"), shown only when it says
    /// something the headline does not.
    let sourceName: String?
    let contentPreview: String?
    let computerName: String
    let connectionStatus: MobileMacConnectionStatus
    /// The spoken details (read state, source, preview, computer) minus the
    /// relative time, which the row formats at render so VoiceOver never reads
    /// a timestamp frozen at whatever moment this model was built.
    let accessibilityDetails: [String]

    init(item: MobileNotificationFeedItem) {
        let normalizedTitle = notificationFeedRowNormalized(item.title)
        let normalizedWorkspace = notificationFeedRowNormalized(item.workspaceTitle)
        let normalizedComputer = notificationFeedRowNormalized(item.macDisplayName) ?? item.macDeviceID

        let headline = normalizedWorkspace ?? normalizedTitle ?? L10n.string(
            "mobile.notificationFeed.row.unknownWorkspace",
            defaultValue: "Unknown workspace"
        )
        self.headline = headline
        if let normalizedTitle, !notificationFeedRowMatches(normalizedTitle, headline) {
            sourceName = normalizedTitle
        } else {
            sourceName = nil
        }
        computerName = normalizedComputer
        connectionStatus = item.connectionStatus

        let redundantContent = [normalizedTitle, normalizedWorkspace, normalizedComputer]
            .compactMap { $0 }
        let contentPreview: String?
        if let body = notificationFeedRowNormalized(item.body),
           !notificationFeedRowMatchesAny(body, redundantContent) {
            contentPreview = body
        } else if let subtitle = notificationFeedRowNormalized(item.subtitle),
                  !notificationFeedRowMatchesAny(subtitle, redundantContent) {
            // The desktop feed treats title + body as the primary content. The
            // optional subtitle becomes useful only when the body adds nothing.
            contentPreview = subtitle
        } else {
            contentPreview = nil
        }
        self.contentPreview = contentPreview

        accessibilityDetails = notificationFeedRowAccessibilityDetails(
            item: item,
            sourceName: sourceName,
            contentPreview: contentPreview,
            computerStatusText: notificationFeedRowApplyingConnectionStatus(
                item.connectionStatus,
                to: normalizedComputer
            )
        )
    }

    var computerStatusText: String {
        notificationFeedRowApplyingConnectionStatus(connectionStatus, to: computerName)
    }
}

private func notificationFeedRowAccessibilityDetails(
    item: MobileNotificationFeedItem,
    sourceName: String?,
    contentPreview: String?,
    computerStatusText: String
) -> [String] {
    var details = [
        item.isRead
            ? L10n.string("mobile.notificationFeed.read", defaultValue: "Read")
            : L10n.string("mobile.notificationFeed.unread", defaultValue: "Unread"),
    ]
    if let sourceName {
        details.append(notificationFeedRowAccessibilityField(
            label: L10n.string("mobile.notificationFeed.row.source", defaultValue: "From"),
            value: sourceName
        ))
    }
    if let contentPreview {
        details.append(contentPreview)
    }
    details.append(notificationFeedRowAccessibilityField(
        label: L10n.string("mobile.notificationFeed.row.computer", defaultValue: "Connection"),
        value: computerStatusText
    ))
    return details
}

// Localized interpolation, not `String(format:)`: these run per row inside
// the detached whole-window rebuild, and C-varargs formatting is banned in
// concurrent hot paths (the PR 5347 regression class). The catalog values
// keep their positional placeholders; interpolation arguments bind to them
// in order.
private func notificationFeedRowAccessibilityField(label: String, value: String) -> String {
    L10n.string(
        "mobile.notificationFeed.row.fieldFormat",
        defaultValue: "\(label): \(value)"
    )
}

private func notificationFeedRowApplyingConnectionStatus(
    _ connectionStatus: MobileMacConnectionStatus,
    to value: String
) -> String {
    switch connectionStatus {
    case .connected:
        return value
    case .reconnecting:
        return L10n.string(
            "mobile.notificationFeed.macReconnectingFormat",
            defaultValue: "\(value) · Reconnecting"
        )
    case .unavailable:
        return L10n.string(
            "mobile.notificationFeed.macUnavailableFormat",
            defaultValue: "\(value) · Unavailable"
        )
    }
}

private func notificationFeedRowNormalized(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
}

private func notificationFeedRowMatchesAny(_ candidate: String, _ values: [String]) -> Bool {
    values.contains { notificationFeedRowMatches(candidate, $0) }
}

private func notificationFeedRowMatches(_ lhs: String, _ rhs: String) -> Bool {
    notificationFeedRowCanonical(lhs) == notificationFeedRowCanonical(rhs)
}

private func notificationFeedRowCanonical(_ value: String) -> String {
    value
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}
