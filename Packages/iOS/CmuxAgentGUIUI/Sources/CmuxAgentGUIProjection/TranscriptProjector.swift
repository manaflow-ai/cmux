import CmuxAgentReplica

/// Projects replica snapshots into immutable transcript row values.
public struct TranscriptProjector: Sendable {
    /// Maximum display-tick distance for grouping consecutive same-role prose.
    public static let groupingTickWindow = 60

    /// Creates a transcript projector.
    public init() {}

    /// Projects input into newest-first rows and computes an identity diff.
    /// - Parameters:
    ///   - input: Value input from a replica snapshot.
    ///   - previousRows: The prior projection, if any.
    /// - Returns: Rows in collection-view order and a row-identity diff.
    public func project(
        _ input: TranscriptProjectionInput,
        previousRows: [TranscriptRow] = []
    ) -> TranscriptProjection {
        var chronological = [TranscriptRow]()
        if input.hasMoreBefore {
            chronological.append(TranscriptRow(rowID: .boundary, rowKind: .boundary))
        }

        let entryContexts = input.entries.map { entry in
            EntryContext(
                entry: entry,
                tick: input.displayTick(entry),
                dayKey: input.dayKey(input.displayTick(entry))
            )
        }
        let proseGroups = Self.proseGroups(for: entryContexts)

        var entryIndex = 0
        var lastDayKey: String?
        for hole in input.holes {
            while entryIndex < entryContexts.count,
                  entryContexts[entryIndex].entry.seq < hole.lowerBound {
                Self.appendEntry(
                    entryContexts[entryIndex],
                    grouping: proseGroups[entryContexts[entryIndex].entry.seq] ?? .single,
                    unreadPointer: input.unreadPointer,
                    lastDayKey: &lastDayKey,
                    rows: &chronological
                )
                entryIndex += 1
            }
            chronological.append(TranscriptRow(rowID: .hole(hole), rowKind: .hole(range: hole)))
            while entryIndex < entryContexts.count,
                  hole.contains(entryContexts[entryIndex].entry.seq) {
                entryIndex += 1
            }
        }
        while entryIndex < entryContexts.count {
            Self.appendEntry(
                entryContexts[entryIndex],
                grouping: proseGroups[entryContexts[entryIndex].entry.seq] ?? .single,
                unreadPointer: input.unreadPointer,
                lastDayKey: &lastDayKey,
                rows: &chronological
            )
            entryIndex += 1
        }

        for ask in input.asks where Self.isActive(ask.state) {
            chronological.append(TranscriptRow(
                rowID: .pendingAsk(ask.id),
                rowKind: .genericActivity(Self.activity(for: ask)),
                isUnread: true
            ))
        }
        for ticket in input.sendTickets where !Self.isResolved(ticket.state) {
            chronological.append(TranscriptRow(
                rowID: .pendingTicket(ticket.id),
                rowKind: .pendingTicket(ticket),
                isUnread: true
            ))
        }
        if let tail = input.streamingTail, !tail.textTail.isEmpty {
            chronological.append(TranscriptRow(
                rowID: .streaming(journalID: tail.journalID, afterSeq: tail.afterSeq),
                rowKind: .streaming(textTail: tail.textTail),
                isUnread: true
            ))
        }

        let rows = Self.deduplicatedRows(chronological).reversed()
        let projected = Array(rows)
        return TranscriptProjection(rows: projected, diff: Self.diff(previous: previousRows, current: projected))
    }

    private static func appendEntry(
        _ context: EntryContext,
        grouping: TranscriptProseGrouping,
        unreadPointer: EntrySeq,
        lastDayKey: inout String?,
        rows: inout [TranscriptRow]
    ) {
        if lastDayKey != context.dayKey {
            rows.append(TranscriptRow(
                rowID: .dateHeader(context.dayKey),
                rowKind: .dateHeader(dayKey: context.dayKey)
            ))
            lastDayKey = context.dayKey
        }
        rows.append(TranscriptRow(
            rowID: .entry(journalID: context.entry.journalID, seq: context.entry.seq),
            rowKind: Self.rowKind(for: context.entry, grouping: grouping),
            isUnread: context.entry.seq.rawValue > unreadPointer.rawValue
        ))
    }

    private static func rowKind(for entry: EntrySnapshot, grouping: TranscriptProseGrouping) -> TranscriptRowKind {
        switch entry.content.payload {
        case .userMessage(let payload):
            .proseUser(text: payload.text, ticketState: nil, grouping: grouping)
        case .agentProse(let payload):
            .proseAgent(text: payload.markdown, grouping: grouping)
        case .thought(let payload):
            .genericActivity(TranscriptGenericActivity(kindLabel: "thought", summary: payload.text))
        case .toolRun(let payload):
            .genericActivity(TranscriptGenericActivity(
                kindLabel: payload.isTerminal ? "command" : "tool",
                summary: Self.joined([payload.toolName, payload.argumentSummary, payload.resultSummary])
            ))
        case .fileChange(let payload):
            .genericActivity(TranscriptGenericActivity(
                kindLabel: "file",
                summary: Self.joined([payload.changeKind.rawValue, payload.path, payload.resultSummary])
            ))
        case .question(let payload):
            .genericActivity(TranscriptGenericActivity(kindLabel: "question", summary: payload.prompt))
        case .permission(let payload):
            .genericActivity(TranscriptGenericActivity(
                kindLabel: "permission",
                summary: Self.joined([payload.toolName, payload.detail])
            ))
        case .status(let payload):
            .status(code: payload.code, detail: payload.detail)
        case .attachment(let payload):
            .genericActivity(TranscriptGenericActivity(kindLabel: payload.kind, summary: payload.summary))
        case .unknown(let payload):
            .unsupported(rawKind: payload.rawKind, summary: payload.summary ?? payload.rawKind)
        }
    }

    private static func proseGroups(for contexts: [EntryContext]) -> [EntrySeq: TranscriptProseGrouping] {
        var result: [EntrySeq: TranscriptProseGrouping] = [:]
        for index in contexts.indices {
            guard let role = contexts[index].proseRole else {
                continue
            }
            let previousConnects: Bool
            if contexts.indices.contains(index - 1), contexts[index - 1].proseRole == role {
                previousConnects = contexts[index].tick - contexts[index - 1].tick <= groupingTickWindow
            } else {
                previousConnects = false
            }
            let nextConnects: Bool
            if contexts.indices.contains(index + 1), contexts[index + 1].proseRole == role {
                nextConnects = contexts[index + 1].tick - contexts[index].tick <= groupingTickWindow
            } else {
                nextConnects = false
            }
            result[contexts[index].entry.seq] = switch (previousConnects, nextConnects) {
            case (false, false): .single
            case (false, true): .first
            case (true, true): .middle
            case (true, false): .last
            }
        }
        return result
    }

    private static func diff(previous: [TranscriptRow], current: [TranscriptRow]) -> TranscriptProjectionDiff {
        let previousIndex = Self.firstIndexes(in: previous)
        let currentIndex = Self.firstIndexes(in: current)
        var inserted: [TranscriptRowID: Int] = [:]
        var removed: [TranscriptRowID: Int] = [:]
        var moved: [TranscriptRowID: TranscriptRowMove] = [:]
        var updated = Set<TranscriptRowID>()

        for row in current {
            let newIndex = currentIndex[row.rowID] ?? 0
            guard let oldIndex = previousIndex[row.rowID] else {
                inserted[row.rowID] = newIndex
                continue
            }
            if previous[oldIndex] != row {
                updated.insert(row.rowID)
            }
        }
        let previousCommon = Self.uniqueRowIDs(in: previous).filter { currentIndex[$0] != nil }
        let currentCommon = Self.uniqueRowIDs(in: current).filter { previousIndex[$0] != nil }
        if previousCommon != currentCommon {
            for rowID in currentCommon where previousIndex[rowID] != currentIndex[rowID] {
                moved[rowID] = TranscriptRowMove(from: previousIndex[rowID] ?? 0, to: currentIndex[rowID] ?? 0)
            }
        }
        for row in previous where currentIndex[row.rowID] == nil {
            removed[row.rowID] = previousIndex[row.rowID] ?? 0
        }
        return TranscriptProjectionDiff(inserted: inserted, removed: removed, moved: moved, updated: updated)
    }

    private static func deduplicatedRows(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var seen = Set<TranscriptRowID>()
        return rows.filter { seen.insert($0.rowID).inserted }
    }

    private static func firstIndexes(in rows: [TranscriptRow]) -> [TranscriptRowID: Int] {
        var result: [TranscriptRowID: Int] = [:]
        for (index, row) in rows.enumerated() where result[row.rowID] == nil {
            result[row.rowID] = index
        }
        return result
    }

    private static func uniqueRowIDs(in rows: [TranscriptRow]) -> [TranscriptRowID] {
        var seen = Set<TranscriptRowID>()
        return rows.compactMap { seen.insert($0.rowID).inserted ? $0.rowID : nil }
    }

    private static func activity(for ask: PendingAsk) -> TranscriptGenericActivity {
        switch ask.kind {
        case .question:
            TranscriptGenericActivity(kindLabel: "question", summary: ask.promptSummary)
        case .permission:
            TranscriptGenericActivity(kindLabel: "permission", summary: ask.promptSummary)
        }
    }

    private static func isActive(_ state: PendingAskState) -> Bool {
        switch state {
        case .active:
            true
        case .answered, .expired, .superseded:
            false
        }
    }

    private static func isResolved(_ state: SendTicketState) -> Bool {
        switch state {
        case .echoed, .failed:
            true
        case .queuedLocal, .acceptedByMac, .injected, .unconfirmed:
            false
        }
    }

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { part in
            let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.joined(separator: " · ")
    }
}
