import Foundation

/// Pure projection helpers for Inbox filtering, chips, rows, and send gating.
public struct InboxPresentationModel: Sendable {
    /// Creates a presentation projection helper.
    public init() {}

    /// Filters items according to a UI list filter and optional source.
    /// - Parameters:
    ///   - items: Candidate items.
    ///   - filter: List filter.
    ///   - source: Optional source filter.
    public func filteredItems(
        _ items: [InboxItem],
        filter: InboxListFilter,
        source: InboxSource?
    ) -> [InboxItem] {
        items.filter { item in
            if let source, item.source != source { return false }
            switch filter {
            case .actionable:
                return item.isActionable
            case .unread:
                return item.isUnread
            case .all:
                return true
            }
        }
    }

    /// Builds source chip snapshots from counts and statuses.
    public func sourceChips(
        selectedSource: InboxSource?,
        counts: [InboxSourceUnreadCount],
        statuses: [InboxConnectorStatus]
    ) -> [InboxSourceChipSnapshot] {
        let countBySource = Dictionary(uniqueKeysWithValues: counts.map { ($0.source, $0.unreadCount) })
        let statusBySource = Dictionary(grouping: statuses, by: \.source).mapValues { values in
            values.map(\.status).sorted(by: Self.statusSort).first
        }
        let total = counts.reduce(0) { $0 + $1.unreadCount }
        var chips = [
            InboxSourceChipSnapshot(
                source: nil,
                label: "All",
                symbolName: "tray.full",
                unreadCount: total,
                isSelected: selectedSource == nil
            ),
        ]
        for source in InboxSource.allCases {
            chips.append(InboxSourceChipSnapshot(
                source: source,
                label: Self.label(for: source),
                symbolName: Self.symbolName(for: source),
                unreadCount: countBySource[source] ?? 0,
                isSelected: selectedSource == source,
                status: statusBySource[source] ?? nil
            ))
        }
        return chips
    }

    /// Builds row snapshots from items and threads.
    public func rows(items: [InboxItem], threads: [InboxThread]) -> [InboxRowSnapshot] {
        let threadByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.threadID, $0) })
        return items.map { InboxRowSnapshot(item: $0, thread: threadByID[$0.threadID]) }
    }

    /// Computes whether a draft can be sent by an explicit approval button.
    /// - Parameter draft: Draft to inspect.
    public func sendState(for draft: InboxDraft?) -> InboxDraftSendState {
        guard let draft else { return .noDraft }
        switch draft.status {
        case .sent:
            return .sent
        case .failed:
            return .failed
        case .editing, .approved:
            return draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyDraft : .requiresApproval
        }
    }

    /// Returns an SF Symbol for a source.
    public static func symbolName(for source: InboxSource) -> String {
        switch source {
        case .agent: return "dot.radiowaves.left.and.right"
        case .gmail: return "envelope"
        case .slack: return "number"
        case .discord: return "gamecontroller"
        case .imessage: return "message"
        case .generic: return "tray"
        }
    }

    /// Returns a display label for a source.
    public static func label(for source: InboxSource) -> String {
        switch source {
        case .agent: return "Agents"
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .discord: return "Discord"
        case .imessage: return "iMessage"
        case .generic: return "Generic"
        }
    }

    private static func statusSort(_ lhs: InboxAccountStatus, _ rhs: InboxAccountStatus) -> Bool {
        severity(lhs) > severity(rhs)
    }

    private static func severity(_ status: InboxAccountStatus) -> Int {
        switch status {
        case .error, .permissionDenied, .tokenExpired:
            return 4
        case .missingCredentials, .missingHelper, .rateLimited:
            return 3
        case .degraded:
            return 2
        case .syncing:
            return 1
        case .connected, .disconnected:
            return 0
        }
    }
}
