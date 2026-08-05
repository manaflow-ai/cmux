import Foundation
public import Observation

/// Maintains the replicated entry window for one session.
@MainActor @Observable public final class ConversationReplica {
    private struct CursorPageSegment {
        var sequenceValues: Set<EntrySeq>
        var startCursor: JournalCursor
        var endCursor: JournalCursor
        var hasMoreBefore: Bool
        var hasMoreAfter: Bool
    }

    /// The session this conversation belongs to.
    public let sessionID: AgentSessionID
    /// The current journal, if known.
    public private(set) var journalID: JournalID?
    /// The advertised tail sequence.
    public private(set) var tailSeq: EntrySeq
    /// Loaded contiguous entry ranges.
    public private(set) var loadedRanges: [EntryRange]
    /// Explicit holes in the entry window.
    public private(set) var holes: [EntryRange]
    /// Whether the sync layer should pull the tail.
    public private(set) var needsTailPull: Bool
    /// Opaque cursor at the oldest loaded source boundary.
    public private(set) var startCursor: JournalCursor?
    /// Opaque cursor at the newest loaded source boundary.
    public private(set) var endCursor: JournalCursor?
    /// Opaque cursor at the server's current committed tail.
    public private(set) var tailCursor: JournalCursor?
    /// Whether a page exists before the loaded cursor coverage.
    public private(set) var hasMoreBefore: Bool
    /// Whether a page exists after the loaded cursor coverage.
    public private(set) var hasMoreAfter: Bool
    /// The read pointer sequence.
    public private(set) var readPointer: EntrySeq
    /// The last origin observed by ``apply(_:origin:)`` or ``mergePage(journal:entries:windowStart:windowEnd:tailSeq:hasMoreBefore:)``.
    public private(set) var lastAppliedOrigin: DeltaOrigin?
    /// Count of journal reset marker row boundaries.
    public private(set) var resetMarkerCount: Int

    @ObservationIgnored private let clock: any ReplicaClock
    private let windowCap: Int
    private var entriesBySeq: [EntrySeq: EntrySnapshot]
    private var versionsBySeq: [EntrySeq: EntityVersion]
    private var ticketLedger: TicketLedgerClient
    private var asksByID: [String: PendingAsk]
    private var hasMoreBeforeWindow: Bool
    private var retentionEdge: ConversationPageRetentionEdge
    private var usesCursorPaging: Bool
    private var cursorPageSegments: [CursorPageSegment]

    /// Creates a conversation replica.
    /// - Parameters:
    ///   - sessionID: The owning session identifier.
    ///   - journalID: The initial journal, if known.
    ///   - tailSeq: The initial advertised tail sequence.
    ///   - readPointer: The retained read pointer.
    ///   - windowCap: The maximum loaded entry count, defaulting to 600.
    ///   - clock: The deterministic clock used by store-owned timing decisions.
    public init(
        sessionID: AgentSessionID,
        journalID: JournalID? = nil,
        tailSeq: EntrySeq = EntrySeq(rawValue: 0),
        readPointer: EntrySeq = EntrySeq(rawValue: 0),
        windowCap: Int = 600,
        usesCursorPaging: Bool = false,
        clock: any ReplicaClock
    ) {
        self.sessionID = sessionID
        self.journalID = journalID
        self.tailSeq = tailSeq
        self.readPointer = readPointer
        self.windowCap = max(1, windowCap)
        self.usesCursorPaging = usesCursorPaging
        self.clock = clock
        loadedRanges = []
        holes = []
        needsTailPull = false
        startCursor = nil
        endCursor = nil
        tailCursor = nil
        hasMoreBefore = false
        hasMoreAfter = false
        lastAppliedOrigin = nil
        resetMarkerCount = 0
        entriesBySeq = [:]
        versionsBySeq = [:]
        ticketLedger = TicketLedgerClient()
        asksByID = [:]
        hasMoreBeforeWindow = false
        retentionEdge = .newest
        cursorPageSegments = []
        _ = clock.tick()
    }

    /// Loaded entries sorted by sequence.
    public var entries: [EntrySnapshot] {
        entriesBySeq.values.sorted { $0.seq < $1.seq }
    }

    /// FIFO send tickets.
    public var sendTickets: [SendTicket] {
        ticketLedger.tickets
    }

    /// Pending asks sorted by identifier.
    public var asks: [PendingAsk] {
        asksByID.values.sorted { $0.id < $1.id }
    }

    /// Count of illegal ticket transitions dropped by the ledger.
    public var illegalTicketTransitionCount: Int {
        ticketLedger.illegalTransitionCount
    }

    /// The derived unread count, exact only when ``unreadIsExact`` is true.
    public var unreadCount: Int {
        if !usesCursorPaging {
            let upper = unreadExactUpperBound()
            return max(0, upper.rawValue - readPointer.rawValue)
        }
        return entriesBySeq.keys.count { $0 > readPointer }
    }

    /// Whether ``unreadCount`` is exact rather than paused by a hole.
    public var unreadIsExact: Bool {
        if !usesCursorPaging {
            return firstHoleAfterReadPointer() == nil
        }
        guard hasMoreBefore, let first = entriesBySeq.keys.min() else { return true }
        return readPointer >= first
    }

    /// Captures value state for deterministic tests and replay comparisons.
    public var state: ConversationReplicaState {
        ConversationReplicaState(
            journalID: journalID,
            tailSeq: tailSeq,
            entries: entries,
            loadedRanges: loadedRanges,
            holes: holes,
            needsTailPull: needsTailPull,
            readPointer: readPointer,
            unreadCount: unreadCount,
            unreadIsExact: unreadIsExact,
            sendTickets: sendTickets,
            asks: asks,
            resetMarkerCount: resetMarkerCount,
            illegalTicketTransitionCount: illegalTicketTransitionCount
        )
    }

    /// Applies one conversation-relevant delta.
    /// - Parameters:
    ///   - delta: The incoming mutation.
    ///   - origin: The mutation origin to expose to observers.
    public func apply(_ delta: ReplicaDelta, origin: DeltaOrigin) {
        let didApply: Bool
        switch delta {
        case .entriesAppended(let journalID, let entries):
            didApply = applyAppend(journalID: journalID, entries: entries)
        case .entryReplaced(let entry):
            didApply = applyReplacement(entry)
        case .journalReset(let sessionID, let newJournal, let tailSeq):
            guard sessionID == self.sessionID else {
                return
            }
            reset(to: newJournal, tailSeq: tailSeq)
            didApply = true
        case .sendTicketChanged(let ticket):
            guard ticket.sessionID == sessionID else {
                return
            }
            didApply = ticketLedger.apply(ticket)
        case .askChanged(let ask):
            guard ask.sessionID == sessionID else {
                return
            }
            asksByID[ask.id] = ask
            didApply = true
        default:
            return
        }
        if didApply {
            lastAppliedOrigin = origin
        }
    }

    /// Merges a pulled page into the loaded entry window.
    /// - Parameters:
    ///   - journal: The journal the page belongs to.
    ///   - entries: Entries in the pulled page.
    ///   - windowStart: The inclusive page window start.
    ///   - windowEnd: The inclusive page window end.
    ///   - tailSeq: The advertised tail sequence.
    ///   - hasMoreBefore: Whether older entries exist before the page.
    ///   - retaining: The edge to preserve if the merged window exceeds its cap.
    public func mergePage(
        journal: JournalID,
        entries: [EntrySnapshot],
        windowStart: EntrySeq,
        windowEnd: EntrySeq,
        tailSeq: EntrySeq,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool = false,
        startCursor: JournalCursor? = nil,
        endCursor: JournalCursor? = nil,
        tailCursor: JournalCursor? = nil,
        requiresPagingRestart: Bool = false,
        replacingWindow: Bool = false,
        retaining requestedEdge: ConversationPageRetentionEdge = .automatic
    ) {
        if startCursor != nil || endCursor != nil || tailCursor != nil {
            usesCursorPaging = true
        }
        if !usesCursorPaging {
            mergeLegacyPage(
                journal: journal,
                entries: entries,
                windowStart: windowStart,
                windowEnd: windowEnd,
                tailSeq: tailSeq,
                hasMoreBefore: hasMoreBefore,
                retaining: requestedEdge
            )
            return
        }
        lastAppliedOrigin = .resync
        let previousRange = loadedRanges.first.map { first in
            (lower: first.lowerBound, upper: loadedRanges.last?.upperBound ?? first.upperBound)
        }
        if journalID != journal || requiresPagingRestart || replacingWindow {
            journalID = journal
            entriesBySeq.removeAll()
            versionsBySeq.removeAll()
            loadedRanges.removeAll()
            holes.removeAll()
            self.startCursor = nil
            self.endCursor = nil
            self.hasMoreBefore = false
            self.hasMoreAfter = false
            cursorPageSegments.removeAll()
        }
        retentionEdge = resolvedRetentionEdge(
            requestedEdge,
            pageStart: windowStart,
            pageEnd: windowEnd,
            previousRange: previousRange
        )
        self.tailSeq = tailSeq
        self.tailCursor = tailCursor ?? self.tailCursor

        for entry in entries where entry.journalID == journal {
            applyEntryValue(entry)
        }
        registerCursorPage(
            entries: entries,
            startCursor: startCursor,
            endCursor: endCursor,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            retaining: retentionEdge
        )
        enforceCursorWindowCap(retaining: retentionEdge)
        refreshCursorCoverage()
        rebuildLoadedRangesFromEntries()
        recomputeHoles()
        // Cursor coverage is normal pagination state, not a repair gap. A
        // successful middle page must remain anchored until the caller asks
        // for another page; live malformed appends and resets set repair
        // urgency through their dedicated paths.
        needsTailPull = false
    }

    /// Marks entries through a sequence as read.
    /// - Parameter seq: The highest read sequence.
    public func markReadThrough(_ seq: EntrySeq) {
        if seq > readPointer {
            readPointer = seq
        }
    }

    /// Applies the epoch-change drop rule for a conversation.
    /// - Parameter epoch: The new Mac app epoch.
    public func handleEpochChange(to epoch: ReplicaEpoch) {
        _ = epoch
        journalID = nil
        tailSeq = EntrySeq(rawValue: 0)
        loadedRanges.removeAll()
        holes.removeAll()
        needsTailPull = false
        entriesBySeq.removeAll()
        versionsBySeq.removeAll()
        asksByID.removeAll()
        resetMarkerCount = 0
        hasMoreBeforeWindow = false
        startCursor = nil
        endCursor = nil
        tailCursor = nil
        hasMoreBefore = false
        hasMoreAfter = false
        cursorPageSegments.removeAll()
        retentionEdge = .newest
        lastAppliedOrigin = .resync
    }

    private func applyAppend(journalID: JournalID, entries: [EntrySnapshot]) -> Bool {
        if !usesCursorPaging {
            return applyLegacyAppend(journalID: journalID, entries: entries)
        }
        guard self.journalID == journalID else {
            return false
        }
        guard !entries.isEmpty else {
            return false
        }
        var previousSeq: EntrySeq?
        var malformedOrder = false
        for entry in entries {
            guard entry.journalID == journalID else {
                malformedOrder = true
                continue
            }
            if let previousSeq, entry.seq <= previousSeq {
                malformedOrder = true
            }
            applyEntryValue(entry)
            previousSeq = entry.seq
        }
        if let lastSeq = entries.map(\.seq).max() {
            tailSeq = max(tailSeq, lastSeq)
        }
        if retentionEdge == .oldest {
            hasMoreAfter = true
        }
        enforceCursorWindowCap(retaining: retentionEdge)
        refreshCursorCoverage()
        rebuildLoadedRangesFromEntries()
        recomputeHoles()
        needsTailPull = malformedOrder
        return true
    }

    private func mergeLegacyPage(
        journal: JournalID,
        entries: [EntrySnapshot],
        windowStart: EntrySeq,
        windowEnd: EntrySeq,
        tailSeq: EntrySeq,
        hasMoreBefore: Bool,
        retaining requestedEdge: ConversationPageRetentionEdge
    ) {
        lastAppliedOrigin = .resync
        let previousRange = loadedRanges.first.map { first in
            (lower: first.lowerBound, upper: loadedRanges.last?.upperBound ?? first.upperBound)
        }
        if journalID != journal {
            journalID = journal
            entriesBySeq.removeAll()
            versionsBySeq.removeAll()
            loadedRanges.removeAll()
            holes.removeAll()
        }
        retentionEdge = resolvedRetentionEdge(
            requestedEdge,
            pageStart: windowStart,
            pageEnd: windowEnd,
            previousRange: previousRange
        )
        self.tailSeq = tailSeq
        hasMoreBeforeWindow = hasMoreBeforeWindow || hasMoreBefore
        self.hasMoreBefore = hasMoreBeforeWindow
        if windowStart.rawValue <= windowEnd.rawValue {
            loadedRanges.append(EntryRange(lowerBound: windowStart, upperBound: windowEnd))
            loadedRanges = Self.coalesced(loadedRanges)
        }
        for entry in entries where entry.journalID == journal {
            applyEntryValue(entry)
        }
        enforceWindowCap(retaining: retentionEdge)
        recomputeHoles()
        needsTailPull = hasRepairableHole
    }

    private func applyLegacyAppend(journalID: JournalID, entries: [EntrySnapshot]) -> Bool {
        guard self.journalID == journalID, let first = entries.first else {
            return false
        }
        if first.seq.rawValue <= tailSeq.rawValue {
            return false
        }
        guard first.seq.rawValue == tailSeq.rawValue + 1 else {
            let lastSeq = entries[entries.count - 1].seq
            tailSeq = max(tailSeq, lastSeq)
            recomputeHoles()
            needsTailPull = true
            return true
        }
        var expected = first.seq.rawValue
        for entry in entries {
            guard entry.journalID == journalID, entry.seq.rawValue == expected else {
                needsTailPull = true
                return true
            }
            applyEntryValue(entry)
            expected += 1
        }
        let lastSeq = entries[entries.count - 1].seq
        loadedRanges.append(EntryRange(lowerBound: first.seq, upperBound: lastSeq))
        loadedRanges = Self.coalesced(loadedRanges)
        tailSeq = lastSeq
        enforceWindowCap(retaining: retentionEdge)
        recomputeHoles()
        return true
    }

    private func applyReplacement(_ entry: EntrySnapshot) -> Bool {
        guard entry.journalID == journalID else {
            return false
        }
        let isLoaded = usesCursorPaging
            ? entriesBySeq[entry.seq] != nil
            : loadedRanges.contains(where: { $0.contains(entry.seq) })
        guard isLoaded else {
            return false
        }
        return applyEntryValue(entry)
    }

    private func reset(to newJournal: JournalID, tailSeq: EntrySeq) {
        journalID = newJournal
        self.tailSeq = tailSeq
        entriesBySeq.removeAll()
        versionsBySeq.removeAll()
        loadedRanges.removeAll()
        holes.removeAll()
        resetMarkerCount += 1
        hasMoreBeforeWindow = tailSeq.rawValue > 0
        startCursor = nil
        endCursor = nil
        tailCursor = nil
        hasMoreBefore = tailSeq.rawValue > 0
        hasMoreAfter = false
        cursorPageSegments.removeAll()
        retentionEdge = .newest
        recomputeHoles()
        needsTailPull = tailSeq.rawValue > 0
    }

    @discardableResult
    private func applyEntryValue(_ entry: EntrySnapshot) -> Bool {
        guard versionsBySeq[entry.seq].map({ entry.version > $0 }) ?? true else {
            return false
        }
        entriesBySeq[entry.seq] = entry
        versionsBySeq[entry.seq] = entry.version
        return true
    }

    private func enforceWindowCap(retaining edge: ConversationPageRetentionEdge) {
        let sorted = entries
        guard sorted.count > windowCap else {
            return
        }
        let removeCount = sorted.count - windowCap
        let removed = edge == .oldest
            ? sorted.suffix(removeCount)
            : sorted.prefix(removeCount)
        for entry in removed {
            entriesBySeq[entry.seq] = nil
            versionsBySeq[entry.seq] = nil
        }
        if edge != .oldest {
            hasMoreBeforeWindow = true
        }
        rebuildLoadedRangesFromEntries()
    }

    private func registerCursorPage(
        entries: [EntrySnapshot],
        startCursor: JournalCursor?,
        endCursor: JournalCursor?,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool,
        retaining edge: ConversationPageRetentionEdge
    ) {
        guard let startCursor, let endCursor else { return }
        cursorPageSegments.removeAll {
            $0.startCursor == startCursor && $0.endCursor == endCursor
        }
        if entries.isEmpty, !cursorPageSegments.isEmpty {
            if edge == .oldest {
                cursorPageSegments[0].startCursor = startCursor
                cursorPageSegments[0].hasMoreBefore = hasMoreBefore
            } else {
                let lastIndex = cursorPageSegments.index(before: cursorPageSegments.endIndex)
                cursorPageSegments[lastIndex].endCursor = endCursor
                cursorPageSegments[lastIndex].hasMoreAfter = hasMoreAfter
            }
            return
        }
        let segment = CursorPageSegment(
            sequenceValues: Set(entries.map(\.seq)),
            startCursor: startCursor,
            endCursor: endCursor,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter
        )
        if edge == .oldest {
            cursorPageSegments.insert(segment, at: 0)
        } else {
            cursorPageSegments.append(segment)
        }
    }

    private func enforceCursorWindowCap(retaining edge: ConversationPageRetentionEdge) {
        if edge == .oldest, entriesBySeq.count > windowCap {
            let segmented = Set(cursorPageSegments.flatMap(\.sequenceValues))
            let unsegmentedNewest = entries
                .filter { !segmented.contains($0.seq) }
                .sorted { $0.seq > $1.seq }
            for entry in unsegmentedNewest where entriesBySeq.count > windowCap {
                entriesBySeq[entry.seq] = nil
                versionsBySeq[entry.seq] = nil
            }
        }

        while entriesBySeq.count > windowCap, cursorPageSegments.count > 1 {
            let removed = edge == .oldest
                ? cursorPageSegments.removeLast()
                : cursorPageSegments.removeFirst()
            let stillRetained = Set(cursorPageSegments.flatMap(\.sequenceValues))
            for seq in removed.sequenceValues where !stillRetained.contains(seq) {
                entriesBySeq[seq] = nil
                versionsBySeq[seq] = nil
            }
        }

        if entriesBySeq.count > windowCap {
            let segmented = Set(cursorPageSegments.flatMap(\.sequenceValues))
            let removable = entries
                .filter { !segmented.contains($0.seq) }
                .sorted { edge == .oldest ? $0.seq > $1.seq : $0.seq < $1.seq }
            for entry in removable where entriesBySeq.count > windowCap {
                entriesBySeq[entry.seq] = nil
                versionsBySeq[entry.seq] = nil
            }
        }

        // A malformed or future server may send one cursor segment larger
        // than the negotiated window. Keep the requested edge bounded even
        // when there is no whole neighboring segment to evict.
        if entriesBySeq.count > windowCap {
            let excess = entriesBySeq.count - windowCap
            let ordered = entriesBySeq.keys.sorted()
            let removed = edge == .oldest
                ? ordered.suffix(excess)
                : ordered.prefix(excess)
            for seq in removed {
                entriesBySeq[seq] = nil
                versionsBySeq[seq] = nil
                for index in cursorPageSegments.indices {
                    cursorPageSegments[index].sequenceValues.remove(seq)
                }
            }
        }
    }

    private func refreshCursorCoverage() {
        guard let first = cursorPageSegments.first, let last = cursorPageSegments.last else {
            startCursor = nil
            endCursor = nil
            hasMoreBefore = false
            hasMoreAfter = false
            hasMoreBeforeWindow = false
            return
        }
        startCursor = first.startCursor
        endCursor = last.endCursor
        hasMoreBefore = first.hasMoreBefore
        hasMoreAfter = last.hasMoreAfter
        hasMoreBeforeWindow = hasMoreBefore
    }

    private func resolvedRetentionEdge(
        _ requested: ConversationPageRetentionEdge,
        pageStart: EntrySeq,
        pageEnd: EntrySeq,
        previousRange: (lower: EntrySeq, upper: EntrySeq)?
    ) -> ConversationPageRetentionEdge {
        guard requested == .automatic else { return requested }
        guard let previousRange else { return .newest }
        if pageEnd < previousRange.lower {
            return .oldest
        }
        if pageStart > previousRange.upper {
            return .newest
        }
        if pageStart < previousRange.lower, pageEnd < previousRange.upper {
            return .oldest
        }
        return retentionEdge == .automatic ? .newest : retentionEdge
    }

    private func rebuildLoadedRangesFromEntries() {
        let seqs = entries.map(\.seq.rawValue).sorted()
        loadedRanges.removeAll()
        if !usesCursorPaging {
            guard var start = seqs.first else { return }
            var previous = start
            for seq in seqs.dropFirst() {
                if seq == previous + 1 {
                    previous = seq
                } else {
                    loadedRanges.append(EntryRange(
                        lowerBound: EntrySeq(rawValue: start),
                        upperBound: EntrySeq(rawValue: previous)
                    ))
                    start = seq
                    previous = seq
                }
            }
            loadedRanges.append(EntryRange(
                lowerBound: EntrySeq(rawValue: start),
                upperBound: EntrySeq(rawValue: previous)
            ))
            return
        }
        guard let first = seqs.first, let last = seqs.last else { return }
        loadedRanges.append(EntryRange(
            lowerBound: EntrySeq(rawValue: first),
            upperBound: EntrySeq(rawValue: last)
        ))
    }

    private func recomputeHoles() {
        guard usesCursorPaging else {
            var nextHoles: [EntryRange] = []
            let ranges = Self.coalesced(loadedRanges)
            if let first = ranges.first, hasMoreBeforeWindow, first.lowerBound.rawValue > 1 {
                nextHoles.append(EntryRange(
                    lowerBound: EntrySeq(rawValue: 1),
                    upperBound: EntrySeq(rawValue: first.lowerBound.rawValue - 1)
                ))
            }
            for pair in zip(ranges, ranges.dropFirst()) {
                let start = pair.0.upperBound.rawValue + 1
                let end = pair.1.lowerBound.rawValue - 1
                if start <= end {
                    nextHoles.append(EntryRange(
                        lowerBound: EntrySeq(rawValue: start),
                        upperBound: EntrySeq(rawValue: end)
                    ))
                }
            }
            if let last = ranges.last {
                let start = last.upperBound.rawValue + 1
                if start <= tailSeq.rawValue {
                    nextHoles.append(EntryRange(lowerBound: EntrySeq(rawValue: start), upperBound: tailSeq))
                }
            } else if tailSeq.rawValue > 0 {
                nextHoles.append(EntryRange(lowerBound: EntrySeq(rawValue: 1), upperBound: tailSeq))
            }
            holes = Self.coalesced(nextHoles)
            return
        }
        holes = []
    }

    private var hasRepairableHole: Bool {
        guard let firstLoaded = loadedRanges.first?.lowerBound else {
            return !holes.isEmpty
        }
        return holes.contains { hole in
            let isPageablePrefix = hasMoreBeforeWindow
                && hole.lowerBound.rawValue == 1
                && hole.upperBound.rawValue < firstLoaded.rawValue
            return !isPageablePrefix
        }
    }

    private func firstHoleAfterReadPointer() -> EntryRange? {
        holes.first { range in
            range.upperBound.rawValue > readPointer.rawValue && range.lowerBound.rawValue <= tailSeq.rawValue
        }
    }

    private func unreadExactUpperBound() -> EntrySeq {
        guard let hole = firstHoleAfterReadPointer() else {
            return tailSeq
        }
        return EntrySeq(rawValue: max(readPointer.rawValue, hole.lowerBound.rawValue - 1))
    }

    private static func coalesced(_ ranges: [EntryRange]) -> [EntryRange] {
        let sorted = ranges.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBound < $1.upperBound
        }
        var output: [EntryRange] = []
        for range in sorted where range.lowerBound.rawValue <= range.upperBound.rawValue {
            guard let last = output.last else {
                output.append(range)
                continue
            }
            if range.lowerBound.rawValue <= last.upperBound.rawValue + 1 {
                output[output.count - 1] = EntryRange(
                    lowerBound: last.lowerBound,
                    upperBound: max(last.upperBound, range.upperBound)
                )
            } else {
                output.append(range)
            }
        }
        return output
    }
}
