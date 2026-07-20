import CmuxAgentReplica

/// Projects replica snapshots into immutable transcript row values.
public struct TranscriptProjector: Sendable {
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

        let entryContexts = input.entries.filter { entry in
            !Self.isKnownInternal(entry.content.payload)
        }.map { entry in
            EntryContext(
                entry: entry,
                tick: input.displayTick(entry),
                dayKey: input.dayKey(input.displayTick(entry))
            )
        }
        var entryIndex = 0
        var lastDayKey: String?
        var lastPromptSeqByJournal: [JournalID: EntrySeq] = [:]
        var turn: TranscriptTurnAccumulator?
        let latestTurnID = Self.latestTurnID(in: entryContexts, holes: input.holes)
        for hole in input.holes {
            while entryIndex < entryContexts.count,
                  entryContexts[entryIndex].entry.seq < hole.lowerBound {
                Self.appendContext(
                    entryContexts[entryIndex],
                    input: input,
                    latestTurnID: latestTurnID,
                    lastDayKey: &lastDayKey,
                    lastPromptSeqByJournal: &lastPromptSeqByJournal,
                    turn: &turn,
                    rows: &chronological
                )
                entryIndex += 1
            }
            Self.flush(
                &turn,
                input: input,
                latestTurnID: latestTurnID,
                rows: &chronological
            )
            chronological.append(TranscriptRow(rowID: .hole(hole), rowKind: .hole(range: hole)))
            while entryIndex < entryContexts.count,
                  hole.contains(entryContexts[entryIndex].entry.seq) {
                entryIndex += 1
            }
        }
        while entryIndex < entryContexts.count {
            Self.appendContext(
                entryContexts[entryIndex],
                input: input,
                latestTurnID: latestTurnID,
                lastDayKey: &lastDayKey,
                lastPromptSeqByJournal: &lastPromptSeqByJournal,
                turn: &turn,
                rows: &chronological
            )
            entryIndex += 1
        }
        Self.flush(&turn, input: input, latestTurnID: latestTurnID, rows: &chronological)

        for ask in input.asks where Self.isActive(ask.state) {
            chronological.append(TranscriptRow(
                rowID: .pendingAsk(ask.id),
                rowKind: .pendingAsk(ask),
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
                isUnread: true,
                turnID: latestTurnID,
                endsTurn: true
            ))
        }

        let rows = Self.deduplicatedRows(chronological).reversed()
        let projected = Array(rows)
        return TranscriptProjection(rows: projected, diff: Self.diff(previous: previousRows, current: projected))
    }

    private static func appendContext(
        _ context: EntryContext,
        input: TranscriptProjectionInput,
        latestTurnID: TranscriptTurnID?,
        lastDayKey: inout String?,
        lastPromptSeqByJournal: inout [JournalID: EntrySeq],
        turn: inout TranscriptTurnAccumulator?,
        rows: inout [TranscriptRow]
    ) {
        if let dayKey = context.dayKey, lastDayKey != dayKey {
            flush(&turn, input: input, latestTurnID: latestTurnID, rows: &rows)
            rows.append(TranscriptRow(
                rowID: .dateHeader(dayKey),
                rowKind: .dateHeader(dayKey: dayKey)
            ))
            lastDayKey = dayKey
        }
        if case .userMessage = context.entry.content.payload {
            flush(&turn, input: input, latestTurnID: latestTurnID, rows: &rows)
            lastPromptSeqByJournal[context.entry.journalID] = context.entry.seq
            turn = TranscriptTurnAccumulator(
                id: TranscriptTurnID(
                    journalID: context.entry.journalID,
                    promptSeq: context.entry.seq,
                    segmentAnchorSeq: context.entry.seq
                ),
                user: context
            )
            return
        }
        if turn?.id.journalID != context.entry.journalID {
            flush(&turn, input: input, latestTurnID: latestTurnID, rows: &rows)
            turn = TranscriptTurnAccumulator(
                id: TranscriptTurnID(
                    journalID: context.entry.journalID,
                    promptSeq: lastPromptSeqByJournal[context.entry.journalID],
                    segmentAnchorSeq: context.entry.seq
                )
            )
        }
        turn?.append(context)
    }

    private static func flush(
        _ turn: inout TranscriptTurnAccumulator?,
        input: TranscriptProjectionInput,
        latestTurnID: TranscriptTurnID?,
        rows: inout [TranscriptRow]
    ) {
        guard let current = turn else {
            return
        }
        turn = nil
        let hasStreaming = current.id == latestTurnID && input.streamingTail?.textTail.isEmpty == false
        let live = current.id == latestTurnID && (
            input.sessionPhase == .starting
                || input.sessionPhase == .working
                || current.activity.contains(where: isRunningActivity)
                || hasStreaming
        )
        var turnRows = [TranscriptRow]()
        if let user = current.user, case .userMessage(let payload) = user.entry.content.payload {
            turnRows.append(entryRow(
                user,
                kind: .proseUser(text: payload.text, ticketState: nil, grouping: .single),
                turnID: current.id,
                unreadPointer: input.unreadPointer
            ))
        }
        let items = current.activity.map(activityItem)
        if !items.isEmpty {
            if live {
                turnRows.append(contentsOf: zip(current.activity, items).map { context, item in
                    entryRow(
                        context,
                        kind: .activityItem(item),
                        turnID: current.id,
                        unreadPointer: input.unreadPointer
                    )
                })
            } else {
                turnRows.append(TranscriptRow(
                    rowID: .activitySummary(current.id),
                    rowKind: .activitySummary(activitySummary(items: items)),
                    isUnread: current.activity.contains { $0.entry.seq > input.unreadPointer },
                    turnID: current.id
                ))
            }
        }
        if let assistant = current.assistant,
           case .agentProse(let payload) = assistant.entry.content.payload {
            turnRows.append(entryRow(
                assistant,
                kind: .proseAgent(text: payload.markdown, grouping: .single),
                turnID: current.id,
                unreadPointer: input.unreadPointer
            ))
        }
        if !hasStreaming, let last = turnRows.popLast() {
            turnRows.append(TranscriptRow(
                rowID: last.rowID,
                rowKind: last.rowKind,
                isUnread: last.isUnread,
                turnID: last.turnID,
                endsTurn: true
            ))
        }
        rows.append(contentsOf: turnRows)
    }

    private static func latestTurnID(
        in contexts: [EntryContext],
        holes: [EntryRange]
    ) -> TranscriptTurnID? {
        var entryIndex = 0
        var lastDayKey: String?
        var lastPromptSeqByJournal: [JournalID: EntrySeq] = [:]
        var currentTurnID: TranscriptTurnID?
        var latestSeenTurnID: TranscriptTurnID?

        func appendIdentity(_ context: EntryContext) {
            if let dayKey = context.dayKey, lastDayKey != dayKey {
                currentTurnID = nil
                lastDayKey = dayKey
            }
            if case .userMessage = context.entry.content.payload {
                lastPromptSeqByJournal[context.entry.journalID] = context.entry.seq
                currentTurnID = TranscriptTurnID(
                    journalID: context.entry.journalID,
                    promptSeq: context.entry.seq,
                    segmentAnchorSeq: context.entry.seq
                )
            } else if currentTurnID?.journalID != context.entry.journalID {
                currentTurnID = TranscriptTurnID(
                    journalID: context.entry.journalID,
                    promptSeq: lastPromptSeqByJournal[context.entry.journalID],
                    segmentAnchorSeq: context.entry.seq
                )
            }
            latestSeenTurnID = currentTurnID
        }

        for hole in holes {
            while entryIndex < contexts.count,
                  contexts[entryIndex].entry.seq < hole.lowerBound {
                appendIdentity(contexts[entryIndex])
                entryIndex += 1
            }
            currentTurnID = nil
            while entryIndex < contexts.count,
                  hole.contains(contexts[entryIndex].entry.seq) {
                entryIndex += 1
            }
        }
        while entryIndex < contexts.count {
            appendIdentity(contexts[entryIndex])
            entryIndex += 1
        }
        return latestSeenTurnID
    }

    private static func entryRow(
        _ context: EntryContext,
        kind: TranscriptRowKind,
        turnID: TranscriptTurnID,
        unreadPointer: EntrySeq
    ) -> TranscriptRow {
        TranscriptRow(
            rowID: .entry(journalID: context.entry.journalID, seq: context.entry.seq),
            rowKind: kind,
            isUnread: context.entry.seq > unreadPointer,
            turnID: turnID
        )
    }

    private static func activityItem(_ context: EntryContext) -> TranscriptActivityItem {
        let entry = context.entry
        let id = TranscriptRowID.entry(journalID: entry.journalID, seq: entry.seq)
        return switch entry.content.payload {
        case .userMessage(let payload):
            TranscriptActivityItem(id: id, kind: .unknown("user"), summary: payload.text, isRunning: false)
        case .agentProse(let payload):
            TranscriptActivityItem(id: id, kind: .assistant, summary: payload.markdown, isRunning: false)
        case .thought(let payload):
            TranscriptActivityItem(id: id, kind: .thought, summary: payload.text, isRunning: false)
        case .toolRun(let payload):
            TranscriptActivityItem(
                id: id,
                kind: payload.isTerminal ? .command : .tool,
                summary: joined([payload.toolName, payload.argumentSummary, payload.resultSummary]),
                isRunning: payload.isRunning
            )
        case .fileChange(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .file,
                summary: joined([payload.changeKind.rawValue, payload.path, payload.resultSummary]),
                isRunning: false
            )
        case .question(let payload):
            TranscriptActivityItem(id: id, kind: .question, summary: payload.prompt, isRunning: false)
        case .permission(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .permission,
                summary: joined([payload.toolName, payload.detail]),
                isRunning: false
            )
        case .status(let payload):
            TranscriptActivityItem(id: id, kind: .status, summary: joined([payload.code.rawValue, payload.detail]), isRunning: false)
        case .attachment(let payload):
            TranscriptActivityItem(id: id, kind: .attachment, summary: joined([payload.kind, payload.summary]), isRunning: false)
        case .unknown(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .unknown(payload.rawKind),
                summary: payload.summary ?? payload.rawKind,
                isRunning: false
            )
        }
    }

    private static func activitySummary(items: [TranscriptActivityItem]) -> TranscriptActivitySummary {
        var fileEditCount = 0
        var toolEditCount = 0
        var readFileCount = 0
        var searchedCode = false
        var listedFiles = false
        var commandCount = 0
        var eventCount = 0
        for item in items {
            switch item.kind {
            case .file:
                fileEditCount += 1
            case .tool, .command:
                commandCount += 1
                let tokens = Set(item.summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                if !tokens.isDisjoint(with: ["read", "cat", "sed", "nl", "open"]) { readFileCount += 1 }
                if !tokens.isDisjoint(with: ["rg", "grep", "search"]) { searchedCode = true }
                if !tokens.isDisjoint(with: ["ls", "find", "list"]) { listedFiles = true }
                if !tokens.isDisjoint(with: ["edit", "write", "apply_patch", "patch"]) { toolEditCount += 1 }
            case .assistant:
                break
            case .thought, .question, .permission, .status, .attachment, .unknown:
                eventCount += 1
            }
        }
        return TranscriptActivitySummary(
            editedFileCount: max(fileEditCount, toolEditCount),
            readFileCount: readFileCount,
            searchedCode: searchedCode,
            listedFiles: listedFiles,
            commandCount: commandCount,
            eventCount: eventCount,
            items: items
        )
    }

    private static func isRunningActivity(_ context: EntryContext) -> Bool {
        if case .toolRun(let payload) = context.entry.content.payload {
            return payload.isRunning
        }
        return false
    }

    private static func isKnownInternal(_ payload: EntryPayload) -> Bool {
        guard case .status(let status) = payload else { return false }
        switch status.code {
        case .sessionMeta:
            return true
        case .other(let rawCode):
            return rawCode == "stop_hook_summary"
        case .compacted, .turnAborted, .apiError:
            return false
        }
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
