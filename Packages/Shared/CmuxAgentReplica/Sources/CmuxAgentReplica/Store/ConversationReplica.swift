import Foundation
public import Observation

/// Maintains the replicated entry window for one session.
@MainActor @Observable public final class ConversationReplica {
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
        clock: any ReplicaClock
    ) {
        self.sessionID = sessionID
        self.journalID = journalID
        self.tailSeq = tailSeq
        self.readPointer = readPointer
        self.windowCap = max(1, windowCap)
        self.clock = clock
        loadedRanges = []
        holes = []
        needsTailPull = false
        lastAppliedOrigin = nil
        resetMarkerCount = 0
        entriesBySeq = [:]
        versionsBySeq = [:]
        ticketLedger = TicketLedgerClient()
        asksByID = [:]
        hasMoreBeforeWindow = false
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
        let upper = unreadExactUpperBound()
        return max(0, upper.rawValue - readPointer.rawValue)
    }

    /// Whether ``unreadCount`` is exact rather than paused by a hole.
    public var unreadIsExact: Bool {
        firstHoleAfterReadPointer() == nil
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
    public func mergePage(
        journal: JournalID,
        entries: [EntrySnapshot],
        windowStart: EntrySeq,
        windowEnd: EntrySeq,
        tailSeq: EntrySeq,
        hasMoreBefore: Bool
    ) {
        lastAppliedOrigin = .resync
        if journalID != journal {
            journalID = journal
            entriesBySeq.removeAll()
            versionsBySeq.removeAll()
            loadedRanges.removeAll()
            holes.removeAll()
        }
        self.tailSeq = tailSeq
        hasMoreBeforeWindow = hasMoreBeforeWindow || hasMoreBefore

        if windowStart.rawValue <= windowEnd.rawValue {
            loadedRanges.append(EntryRange(lowerBound: windowStart, upperBound: windowEnd))
            loadedRanges = Self.coalesced(loadedRanges)
        }

        for entry in entries where entry.journalID == journal {
            applyEntryValue(entry)
        }
        enforceWindowCap()
        recomputeHoles()
        needsTailPull = !holes.isEmpty
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
        lastAppliedOrigin = .resync
    }

    private func applyAppend(journalID: JournalID, entries: [EntrySnapshot]) -> Bool {
        guard self.journalID == journalID else {
            return false
        }
        guard let first = entries.first else {
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
        enforceWindowCap()
        recomputeHoles()
        return true
    }

    private func applyReplacement(_ entry: EntrySnapshot) -> Bool {
        guard entry.journalID == journalID else {
            return false
        }
        guard loadedRanges.contains(where: { $0.contains(entry.seq) }) else {
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

    private func enforceWindowCap() {
        let sorted = entries
        guard sorted.count > windowCap else {
            return
        }
        let removeCount = sorted.count - windowCap
        let removed = sorted.prefix(removeCount)
        for entry in removed {
            entriesBySeq[entry.seq] = nil
            versionsBySeq[entry.seq] = nil
        }
        hasMoreBeforeWindow = true
        rebuildLoadedRangesFromEntries()
    }

    private func rebuildLoadedRangesFromEntries() {
        let seqs = entries.map(\.seq.rawValue).sorted()
        loadedRanges.removeAll()
        guard var start = seqs.first else {
            return
        }
        var previous = start
        for seq in seqs.dropFirst() {
            if seq == previous + 1 {
                previous = seq
            } else {
                loadedRanges.append(EntryRange(lowerBound: EntrySeq(rawValue: start), upperBound: EntrySeq(rawValue: previous)))
                start = seq
                previous = seq
            }
        }
        loadedRanges.append(EntryRange(lowerBound: EntrySeq(rawValue: start), upperBound: EntrySeq(rawValue: previous)))
    }

    private func recomputeHoles() {
        var nextHoles: [EntryRange] = []
        let ranges = Self.coalesced(loadedRanges)
        if let first = ranges.first, hasMoreBeforeWindow, first.lowerBound.rawValue > 1 {
            nextHoles.append(EntryRange(lowerBound: EntrySeq(rawValue: 1), upperBound: EntrySeq(rawValue: first.lowerBound.rawValue - 1)))
        }
        for pair in zip(ranges, ranges.dropFirst()) {
            let start = pair.0.upperBound.rawValue + 1
            let end = pair.1.lowerBound.rawValue - 1
            if start <= end {
                nextHoles.append(EntryRange(lowerBound: EntrySeq(rawValue: start), upperBound: EntrySeq(rawValue: end)))
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
