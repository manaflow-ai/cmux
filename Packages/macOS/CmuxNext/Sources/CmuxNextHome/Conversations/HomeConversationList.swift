public import CmuxHomeCore
import CmuxNextHomeModel
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
    /// The rows (inbox order: pinned by rank, then newest first) in sections; each keeps that order
    /// (`inbox.sections`).
    public var homeSections: [HomeConversationSection] {
        let sections: [SectionReply] = HomeInboxRules().call("sections", RowsRequest(rows: HomeInboxRules().rows(self)), fallback: [])
        return sections.compactMap { section in
            guard let kind = HomeConversationSectionKind(rules: section.kind) else {
                assertionFailure("inbox.sections: unknown kind \(section.kind)")
                return nil
            }
            return HomeConversationSection(kind: kind, rows: HomeInboxRules().pick(section.rows, from: self))
        }
    }

    public var homeLines: [HomeConversationLine] {
        homeSections.flatMap { section in [.header(section.kind)] + section.rows.map(HomeConversationLine.row) }
    }

    /// The conversations the user invited someone into who has not joined
    /// yet, with the address each invite went to (`inbox.pending_invites`).
    public var pendingInvites: [(conversation: ConversationID, contact: String)] {
        let invites: [InviteReply] = HomeInboxRules().call("pending_invites", RowsRequest(rows: HomeInboxRules().rows(self)), fallback: [])
        return invites.map { (ConversationID(rawValue: $0.conversation), $0.contact) }
    }
}

extension HomeConversationSectionKind {
    /// The kind `inbox::list::SectionKind` names.
    init?(rules name: String) {
        switch name {
        case "chiefs": self = .chiefs
        case "pinned": self = .pinned
        case "messages": self = .messages
        case "invited": self = .invited
        default: return nil
        }
    }
}

private nonisolated struct RowsRequest: Encodable {
    var rows: [HomeInboxRules.Row]
}

private nonisolated struct SectionReply: Decodable {
    var kind: String
    var rows: [String]
}

private nonisolated struct InviteReply: Decodable {
    var conversation: String
    var contact: String
}
