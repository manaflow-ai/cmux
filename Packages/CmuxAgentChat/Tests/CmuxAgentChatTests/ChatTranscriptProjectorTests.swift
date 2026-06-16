import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatTranscriptProjector")
struct ChatTranscriptProjectorTests {
    // MARK: - Fixtures

    /// 2026-06-10T12:00:00Z, comfortably mid-day in UTC.
    private static let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func makeProjector(groupingInterval: TimeInterval = 60) -> ChatTranscriptProjector {
        ChatTranscriptProjector(groupingInterval: groupingInterval, calendar: utcCalendar)
    }

    private static func prose(
        seq: Int,
        role: ChatRole = .agent,
        offset: TimeInterval = 0,
        text: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: role,
            timestamp: baseTime.addingTimeInterval(offset),
            kind: .prose(ChatProse(text: text ?? "text \(seq)"))
        )
    }

    private static func message(
        seq: Int,
        role: ChatRole = .agent,
        offset: TimeInterval = 0,
        kind: ChatMessageKind
    ) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: role,
            timestamp: baseTime.addingTimeInterval(offset),
            kind: kind
        )
    }

    private static func snapshots(_ rows: [ChatTranscriptRow]) -> [ChatMessageRowSnapshot] {
        rows.compactMap {
            if case .message(let snapshot) = $0 { return snapshot }
            return nil
        }
    }

    private static func pending(id: String, text: String) -> ChatPendingOutbound {
        ChatPendingOutbound(
            id: id,
            text: text,
                        createdAt: baseTime,
            delivery: .sending
        )
    }

    // MARK: - Date headers

    @Test("date header precedes the first message of each day")
    func dateHeadersAtDayBoundaries() {
        let projector = Self.makeProjector()
        let dayLength: TimeInterval = 86_400
        let messages = [
            Self.prose(seq: 0, offset: 0),
            Self.prose(seq: 1, offset: 30),
            Self.prose(seq: 2, offset: dayLength), // next UTC day
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)

        let headerIndexes = rows.indices.filter {
            if case .dateHeader = rows[$0] { return true }
            return false
        }
        #expect(headerIndexes == [0, 3])

        let cal = Self.utcCalendar
        guard case .dateHeader(let firstDay) = rows[0],
              case .dateHeader(let secondDay) = rows[3] else {
            Issue.record("expected date header rows at 0 and 3, got \(rows)")
            return
        }
        #expect(firstDay == cal.startOfDay(for: messages[0].timestamp))
        #expect(secondDay == cal.startOfDay(for: messages[2].timestamp))
        #expect(firstDay != secondDay)
    }

    @Test("a single day yields exactly one header")
    func singleDayOneHeader() {
        let projector = Self.makeProjector()
        let messages = (0..<5).map { Self.prose(seq: $0, offset: TimeInterval($0) * 10) }
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let headerCount = rows.filter {
            if case .dateHeader = $0 { return true }
            return false
        }.count
        #expect(headerCount == 1)
    }

    @Test("same-role prose within the interval does not group across midnight")
    func dayBoundarySplitsGroup() {
        let projector = Self.makeProjector()
        // Two messages 20s apart straddling the UTC midnight between them.
        let midnight = Self.utcCalendar.startOfDay(for: Self.baseTime).addingTimeInterval(86_400)
        let messages = [
            ChatMessage(
                id: "a", seq: 0, role: .agent,
                timestamp: midnight.addingTimeInterval(-10),
                kind: .prose(ChatProse(text: "before"))
            ),
            ChatMessage(
                id: "b", seq: 1, role: .agent,
                timestamp: midnight.addingTimeInterval(10),
                kind: .prose(ChatProse(text: "after"))
            ),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.groupPosition) == [.solo, .solo])
    }

    // MARK: - Grouping

    @Test("same-role prose within 60s groups first/middle/last")
    func groupsWithinInterval() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, offset: 0),
            Self.prose(seq: 1, offset: 30),
            Self.prose(seq: 2, offset: 60),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.groupPosition) == [.first, .middle, .last])
    }

    @Test("a gap over the grouping interval splits the group")
    func gapSplitsGroup() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, offset: 0),
            Self.prose(seq: 1, offset: 30),
            Self.prose(seq: 2, offset: 30 + 61), // 61s after its predecessor
            Self.prose(seq: 3, offset: 30 + 61 + 30),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.groupPosition) == [.first, .last, .first, .last])
    }

    @Test("a role change splits the group")
    func roleChangeSplitsGroup() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, role: .agent, offset: 0),
            Self.prose(seq: 1, role: .agent, offset: 10),
            Self.prose(seq: 2, role: .user, offset: 20),
            Self.prose(seq: 3, role: .agent, offset: 30),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.groupPosition) == [.first, .last, .solo, .solo])
    }

    @Test("an isolated message is solo")
    func soloPosition() {
        let projector = Self.makeProjector()
        let rows = projector.rows(
            messages: [Self.prose(seq: 0)],
            pending: [],
            firstUnreadSeq: nil
        )
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.groupPosition) == [.solo])
        #expect(snaps.map(\.showsTimestamp) == [true])
    }

    @Test("status, permission, and question kinds never group and break neighbors")
    func nonGroupableKindsStandAlone() {
        let projector = Self.makeProjector()
        let nonGroupable: [ChatMessageKind] = [
            .status(ChatStatusTransition(event: .sessionStarted)),
            .permissionRequest(ChatPermissionRequest(title: "Run:", subject: "ls")),
            .question(ChatQuestion(prompt: "Which?", options: [ChatQuestion.Option(label: "A")])),
            // Full-width cards (and the thought row) render without a bubble and
            // ignore groupPosition/showsTimestamp, so they must NOT participate
            // in bubble grouping: otherwise an adjacent prose bubble gets a
            // tightened corner pointing at a card and the group's timestamp can
            // land on a card that never draws it.
            .thought(ChatThought(text: "considering options")),
            .toolUse(ChatToolUse(toolName: "Read", summary: "Read file", status: .succeeded)),
            .terminal(ChatTerminalCapture(command: "ls")),
            .fileEdit(ChatFileEdit(filePath: "a.swift", operation: .edit, additions: 1, deletions: 0, unifiedDiff: "-a\n+b")),
        ]
        for kind in nonGroupable {
            let messages = [
                Self.prose(seq: 0, offset: 0),
                Self.message(seq: 1, offset: 10, kind: kind),
                Self.prose(seq: 2, offset: 20),
            ]
            let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
            let snaps = Self.snapshots(rows)
            #expect(snaps.map(\.groupPosition) == [.solo, .solo, .solo], "kind: \(kind)")
        }
    }

    @Test("a card between prose keeps each prose bubble's own timestamp")
    func cardBreaksGroupTimestamp() {
        let projector = Self.makeProjector()
        // prose, toolUse-card, prose — all agent within the interval. The card
        // must break the run so each prose shows its own timestamp (the bug:
        // grouping spanned the card and put showsTimestamp on the card, hiding
        // both prose timestamps).
        let messages = [
            Self.prose(seq: 0, offset: 0),
            Self.message(seq: 1, offset: 10, kind: .toolUse(
                ChatToolUse(toolName: "Read", summary: "Read file", status: .succeeded)
            )),
            Self.prose(seq: 2, offset: 20),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.groupPosition) == [.solo, .solo, .solo])
        #expect(snaps.map(\.showsTimestamp) == [true, true, true])
    }

    @Test("showsTimestamp is true only on the last row of each group")
    func timestampOnlyOnGroupTail() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, offset: 0),
            Self.prose(seq: 1, offset: 10),
            Self.prose(seq: 2, offset: 20),
            Self.prose(seq: 3, role: .user, offset: 30),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let snaps = Self.snapshots(rows)
        #expect(snaps.map(\.showsTimestamp) == [false, false, true, true])
    }

    // MARK: - Unread separator

    @Test("unread separator sits before the message with firstUnreadSeq")
    func unreadSeparatorBeforeFirstUnread() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, role: .user, offset: 0),
            Self.prose(seq: 1, role: .agent, offset: 200),
            Self.prose(seq: 2, role: .agent, offset: 210),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: 1)
        guard let separatorIndex = rows.firstIndex(of: .unreadSeparator) else {
            Issue.record("missing unread separator in \(rows)")
            return
        }
        guard case .message(let next) = rows[separatorIndex + 1] else {
            Issue.record("expected a message right after the separator")
            return
        }
        #expect(next.message.seq == 1)
    }

    @Test("unread separator lands inside what would otherwise be one group")
    func unreadSeparatorInsideGroup() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, offset: 0),
            Self.prose(seq: 1, offset: 10),
            Self.prose(seq: 2, offset: 20),
        ]
        let rows = projector.rows(messages: messages, pending: [], firstUnreadSeq: 1)
        guard let separatorIndex = rows.firstIndex(of: .unreadSeparator) else {
            Issue.record("missing unread separator in \(rows)")
            return
        }
        guard case .message(let before) = rows[separatorIndex - 1],
              case .message(let after) = rows[separatorIndex + 1] else {
            Issue.record("expected message rows around the separator in \(rows)")
            return
        }
        #expect(before.message.seq == 0)
        #expect(after.message.seq == 1)
    }

    @Test("no separator when firstUnreadSeq is nil or absent")
    func noSeparatorWithoutUnread() {
        let projector = Self.makeProjector()
        let messages = [Self.prose(seq: 0), Self.prose(seq: 1, offset: 10)]
        let withNil = projector.rows(messages: messages, pending: [], firstUnreadSeq: nil)
        let withMissingSeq = projector.rows(messages: messages, pending: [], firstUnreadSeq: 99)
        #expect(!withNil.contains(.unreadSeparator))
        #expect(!withMissingSeq.contains(.unreadSeparator))
    }

    // MARK: - Pending outbound

    @Test("pending outbound rows append at the end, in order")
    func pendingRowsAppendAtEnd() {
        let projector = Self.makeProjector()
        let pendingItems = [
            Self.pending(id: "local-1", text: "first"),
            Self.pending(id: "local-2", text: "second"),
        ]
        let rows = projector.rows(
            messages: [Self.prose(seq: 0)],
            pending: pendingItems,
            firstUnreadSeq: nil
        )
        guard rows.count >= 2,
              case .pendingOutbound(let tail1) = rows[rows.count - 2],
              case .pendingOutbound(let tail2) = rows[rows.count - 1] else {
            Issue.record("expected two trailing pending rows in \(rows)")
            return
        }
        #expect(tail1.id == "local-1")
        #expect(tail2.id == "local-2")
    }

    // MARK: - Row identity

    @Test("row ids are distinct and deterministic across projections")
    func stableRowIDs() {
        let projector = Self.makeProjector()
        let messages = [
            Self.prose(seq: 0, role: .user, offset: 0),
            Self.prose(seq: 1, role: .agent, offset: 30),
            Self.message(
                seq: 2, role: .system, offset: 40,
                kind: .status(ChatStatusTransition(event: .interrupted))
            ),
            Self.prose(seq: 3, role: .agent, offset: 86_400),
        ]
        let pendingItems = [Self.pending(id: "local-1", text: "out")]

        let first = projector.rows(messages: messages, pending: pendingItems, firstUnreadSeq: 1)
        let second = projector.rows(messages: messages, pending: pendingItems, firstUnreadSeq: 1)

        let firstIDs = first.map(\.id)
        #expect(Set(firstIDs).count == firstIDs.count, "ids must be distinct: \(firstIDs)")
        #expect(firstIDs == second.map(\.id))
    }
}
