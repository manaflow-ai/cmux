import Foundation

/// Pure projection of transcript messages into renderable rows: date
/// headers, the unread separator, bubble grouping, and pending outbound
/// placement.
///
/// Stateless and synchronous so it is trivially testable; the
/// ``ChatConversationStore`` re-runs it over its (bounded) message window
/// whenever inputs change.
public struct ChatTranscriptProjector: Sendable {
    /// Maximum gap between two same-author messages that still groups them
    /// into one visual bubble group.
    public let groupingInterval: TimeInterval

    /// Calendar used to place date headers at day boundaries.
    public let calendar: Calendar

    /// Creates a projector.
    ///
    /// - Parameters:
    ///   - groupingInterval: Maximum same-author gap that still groups,
    ///     in seconds.
    ///   - calendar: Calendar for day-boundary date headers.
    public init(groupingInterval: TimeInterval = 60, calendar: Calendar = .current) {
        self.groupingInterval = groupingInterval
        self.calendar = calendar
    }

    /// Projects messages and pending sends into the renderable row list.
    ///
    /// - Parameters:
    ///   - messages: The message window, ordered by ascending seq.
    ///   - pending: Optimistic outgoing rows, appended after all messages.
    ///   - firstUnreadSeq: Seq of the first unseen message; an unread
    ///     separator is inserted before it when present.
    /// - Returns: Rows in display order (oldest first).
    public func rows(
        messages: [ChatMessage],
        pending: [ChatPendingOutbound],
        firstUnreadSeq: Int?
    ) -> [ChatTranscriptRow] {
        var rows: [ChatTranscriptRow] = []
        rows.reserveCapacity(messages.count + pending.count + 8)

        var currentDay: Date?
        var index = 0
        var insertedUnreadSeparator = false
        while index < messages.count {
            let message = messages[index]
            let day = calendar.startOfDay(for: message.timestamp)
            if day != currentDay {
                currentDay = day
                rows.append(.dateHeader(day: day))
            }
            if let firstUnreadSeq, !insertedUnreadSeparator, message.seq >= firstUnreadSeq {
                insertedUnreadSeparator = true
                rows.append(.unreadSeparator)
            }

            let groupEnd = groupEndIndex(in: messages, startingAt: index, day: day)
            let groupLength = groupEnd - index
            for offset in 0..<groupLength {
                let member = messages[index + offset]
                if let firstUnreadSeq, !insertedUnreadSeparator, offset > 0, member.seq >= firstUnreadSeq {
                    // An unread boundary inside a group still gets the
                    // separator; the group visually splits there.
                    insertedUnreadSeparator = true
                    rows.append(.unreadSeparator)
                }
                rows.append(
                    .message(
                        ChatMessageRowSnapshot(
                            message: member,
                            groupPosition: position(offset: offset, count: groupLength),
                            showsTimestamp: offset == groupLength - 1
                        )
                    )
                )
            }
            index = groupEnd
        }

        for item in pending {
            rows.append(.pendingOutbound(item))
        }
        return rows
    }

    /// Returns the exclusive end index of the bubble group starting at
    /// `start`: consecutive same-author groupable messages within
    /// ``groupingInterval`` of their predecessor, on the same day.
    private func groupEndIndex(in messages: [ChatMessage], startingAt start: Int, day: Date) -> Int {
        let head = messages[start]
        guard isGroupable(head) else { return start + 1 }
        var end = start + 1
        var previous = head
        while end < messages.count {
            let candidate = messages[end]
            guard
                isGroupable(candidate),
                candidate.role == head.role,
                candidate.timestamp.timeIntervalSince(previous.timestamp) <= groupingInterval,
                calendar.startOfDay(for: candidate.timestamp) == day
            else { break }
            previous = candidate
            end += 1
        }
        return end
    }

    /// Whether a message participates in bubble grouping. Only the bubble-
    /// rendered kinds (prose, attachment) group: they are the rows that consume
    /// `groupPosition`/`showsTimestamp`. The thought row and the full-width
    /// cards (toolUse, terminal, fileEdit) ignore both, so grouping them would
    /// tighten a neighbor bubble's corner toward a card and could land the
    /// group timestamp on a card that never draws it. Status/permission/
    /// question/unsupported also stand alone.
    private func isGroupable(_ message: ChatMessage) -> Bool {
        switch message.kind {
        case .prose, .attachment:
            return true
        case .status, .permissionRequest, .question, .unsupported,
             .thought, .toolUse, .terminal, .fileEdit:
            return false
        }
    }

    private func position(offset: Int, count: Int) -> ChatGroupPosition {
        if count == 1 { return .solo }
        if offset == 0 { return .first }
        if offset == count - 1 { return .last }
        return .middle
    }
}
