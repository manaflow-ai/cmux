import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

/// A feed row prepared off the main actor: the immutable item plus every
/// derived string the row renders. Rows used to normalize, fold, and format
/// these inside `body`, which ran per row materialization during scroll; the
/// projection now builds one model per item on its background rebuild task.
struct NotificationFeedRowModel: Identifiable, Equatable, Sendable {
    let item: MobileNotificationFeedItem
    let presentation: NotificationFeedRowPresentation

    init(item: MobileNotificationFeedItem) {
        self.item = item
        presentation = NotificationFeedRowPresentation(item: item)
    }

    var id: MobileNotificationFeedItemID { item.id }
    var notificationID: String { item.notificationID }

    /// `presentation` is a pure derivation of `item` (plus the rebuild time for
    /// the spoken relative date), so equality compares the item alone and list
    /// diffs stay as cheap as they were with raw-item sections.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
    }
}

/// A compact, immutable projection of the four facts a user scans before
/// opening, plus the row's precomputed accessibility value.
struct NotificationFeedRowPresentation: Equatable, Sendable {
    let workspaceName: String
    let workspaceMatchesTitle: Bool
    let contentPreview: String?
    let computerName: String
    let connectionStatus: MobileMacConnectionStatus
    /// The full spoken value (read state, workspace, preview, computer,
    /// relative time). The relative time anchors to the rebuild that produced
    /// this model, matching the staleness of the day headers around it.
    let accessibilityValue: String

    init(item: MobileNotificationFeedItem) {
        let normalizedTitle = Self.normalized(item.title) ?? item.title
        let normalizedWorkspace = Self.normalized(item.workspaceTitle) ?? L10n.string(
            "mobile.notificationFeed.row.unknownWorkspace",
            defaultValue: "Unknown workspace"
        )
        let normalizedComputer = Self.normalized(item.macDisplayName) ?? item.macDeviceID

        workspaceName = normalizedWorkspace
        workspaceMatchesTitle = Self.matches(normalizedWorkspace, normalizedTitle)
        computerName = normalizedComputer
        connectionStatus = item.connectionStatus

        let redundantContent = [normalizedTitle, normalizedWorkspace, normalizedComputer]
        let contentPreview: String?
        if let body = Self.normalized(item.body),
           !Self.matchesAny(body, redundantContent) {
            contentPreview = body
        } else if let subtitle = Self.normalized(item.subtitle),
                  !Self.matchesAny(subtitle, redundantContent) {
            // The desktop feed treats title + body as the primary content. The
            // optional subtitle becomes useful only when the body adds nothing.
            contentPreview = subtitle
        } else {
            contentPreview = nil
        }
        self.contentPreview = contentPreview

        accessibilityValue = Self.accessibilityValue(
            item: item,
            workspaceName: normalizedWorkspace,
            contentPreview: contentPreview,
            computerStatusText: Self.applyingConnectionStatus(
                item.connectionStatus,
                to: normalizedComputer
            )
        )
    }

    var computerStatusText: String {
        Self.applyingConnectionStatus(connectionStatus, to: computerName)
    }

    private static func accessibilityValue(
        item: MobileNotificationFeedItem,
        workspaceName: String,
        contentPreview: String?,
        computerStatusText: String
    ) -> String {
        var details = [
            item.isRead
                ? L10n.string("mobile.notificationFeed.read", defaultValue: "Read")
                : L10n.string("mobile.notificationFeed.unread", defaultValue: "Unread"),
        ]
        details.append(accessibilityField(
            label: L10n.string("mobile.notificationFeed.row.workspace", defaultValue: "Workspace"),
            value: workspaceName
        ))
        if let contentPreview {
            details.append(contentPreview)
        }
        details.append(accessibilityField(
            label: L10n.string("mobile.notificationFeed.row.computer", defaultValue: "Computer"),
            value: computerStatusText
        ))
        details.append(item.createdAt.formatted(.relative(presentation: .named)))
        return details.formatted()
    }

    private static func accessibilityField(label: String, value: String) -> String {
        String(
            format: L10n.string(
                "mobile.notificationFeed.row.fieldFormat",
                defaultValue: "%1$@: %2$@"
            ),
            label,
            value
        )
    }

    private static func applyingConnectionStatus(
        _ connectionStatus: MobileMacConnectionStatus,
        to value: String
    ) -> String {
        switch connectionStatus {
        case .connected:
            return value
        case .reconnecting:
            return String(
                format: L10n.string(
                    "mobile.notificationFeed.macReconnectingFormat",
                    defaultValue: "%@ · Reconnecting"
                ),
                value
            )
        case .unavailable:
            return String(
                format: L10n.string(
                    "mobile.notificationFeed.macUnavailableFormat",
                    defaultValue: "%@ · Unavailable"
                ),
                value
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func matchesAny(_ candidate: String, _ values: [String]) -> Bool {
        values.contains { matches(candidate, $0) }
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
