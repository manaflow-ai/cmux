public import CmuxHomeCore
import Foundation

/// A section of the Home page's conversation list (its left column).
public enum HomeConversationSectionKind: Hashable, Sendable, CaseIterable {
    case chiefs
    case pinned
    case messages
    case invited
}

/// One section and its rows, in inbox order.
public struct HomeConversationSection: Hashable, Sendable {
    public var kind: HomeConversationSectionKind
    public var rows: [InboxRow]
}

/// One table line: a section header or a conversation.
public enum HomeConversationLine: Hashable, Sendable {
    case header(HomeConversationSectionKind)
    case row(InboxRow)

    public var conversation: ConversationID? {
        if case .row(let row) = self { row.id } else { nil }
    }
}

/// The merged inbox (local and cloud conversations, `HomeStore.rows`) in
/// the list's sections: Chiefs first, then pinned conversations, then DMs
/// and groups by newest activity, then DMs still waiting for an invited
/// person. A section with no rows is left out, so someone without Chiefs
/// sees only messages.
extension Array where Element == InboxRow {
    /// The rows (inbox order: pinned by rank, then newest first) in sections; each keeps that order.
    public var homeSections: [HomeConversationSection] {
        var buckets: [HomeConversationSectionKind: [InboxRow]] = [:]
        for row in self { buckets[row.homeSectionKind, default: []].append(row) }
        return HomeConversationSectionKind.allCases.compactMap { kind in
            guard let rows = buckets[kind], !rows.isEmpty else { return nil }
            return HomeConversationSection(kind: kind, rows: rows)
        }
    }

    public var homeLines: [HomeConversationLine] {
        homeSections.flatMap { section in [.header(section.kind)] + section.rows.map(HomeConversationLine.row) }
    }

    /// The conversations the user invited someone into who has not joined
    /// yet, with the address each invite went to.
    public var pendingInvites: [(conversation: ConversationID, contact: String)] {
        flatMap { row in
            row.summary.participants.filter { $0.membership == .invited }.map { (row.id, $0.invitedContact ?? $0.displayName) }
        }
    }
}

extension InboxRow {
    var homeSectionKind: HomeConversationSectionKind {
        if kind == .chief { return .chiefs }
        if isPinned { return .pinned }
        if kind == .direct, summary.hasInvitedParticipant { return .invited }
        return .messages
    }
}
