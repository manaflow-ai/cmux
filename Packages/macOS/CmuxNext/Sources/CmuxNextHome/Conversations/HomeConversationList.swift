public import CmuxHomeCore
import Foundation

/// The Home page's conversation list (its left column): the merged inbox
/// (local and cloud conversations, `HomeStore.rows`) in sections. Chiefs
/// come first, then pinned conversations, then DMs and groups by newest
/// activity, then DMs still waiting for an invited person. A section with
/// no rows is left out, so someone without Chiefs sees only messages.
public enum HomeConversationList {
    public enum SectionKind: Hashable, Sendable, CaseIterable {
        case chiefs
        case pinned
        case messages
        case invited
    }

    public struct Section: Hashable, Sendable {
        public var kind: SectionKind
        public var rows: [InboxRow]
    }

    /// One table line: a section header or a conversation.
    public enum Line: Hashable, Sendable {
        case header(SectionKind)
        case row(InboxRow)

        public var conversation: ConversationID? {
            if case .row(let row) = self { row.id } else { nil }
        }
    }

    /// `rows` arrive in inbox order (pinned by rank, then newest first);
    /// each section keeps that order.
    public static func sections(_ rows: [InboxRow]) -> [Section] {
        var buckets: [SectionKind: [InboxRow]] = [:]
        for row in rows { buckets[kind(of: row), default: []].append(row) }
        return SectionKind.allCases.compactMap { kind in
            guard let rows = buckets[kind], !rows.isEmpty else { return nil }
            return Section(kind: kind, rows: rows)
        }
    }

    public static func lines(_ rows: [InboxRow]) -> [Line] {
        sections(rows).flatMap { section in [.header(section.kind)] + section.rows.map(Line.row) }
    }

    static func kind(of row: InboxRow) -> SectionKind {
        if row.kind == .chief { return .chiefs }
        if row.isPinned { return .pinned }
        if row.kind == .direct, row.summary.hasInvitedParticipant { return .invited }
        return .messages
    }

    /// The conversations the user invited someone into who has not joined
    /// yet, newest first, with the address each invite went to.
    public static func pendingInvites(_ rows: [InboxRow]) -> [(conversation: ConversationID, contact: String)] {
        rows.flatMap { row in
            row.summary.participants.filter { $0.membership == .invited }.map { (row.id, $0.invitedContact ?? $0.displayName) }
        }
    }
}
