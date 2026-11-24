import Foundation
import Observation

// The data the chat polish rows read (cmux#25834, parity with the Mac's
// AgentChatCopyActionCatalog, Session Info, AgentTranscriptActionCatalog, the
// permission actions, the Event Inspector and Replay Conversation).

/// A chat's identity and status as the Mac's acpmux reports it (`_acpmux/info`): what the
/// Copy rows copy and Session Info shows.
public struct AgentSessionDetails: Hashable, Sendable {
    /// The agent's name for the chat (acpmux `name`).
    public var name: String?
    /// The chat's acpmux id (the Mac's "Agent identifier").
    public var sessionID: String
    /// The harness's own session id (Claude Code's or Codex's, `agentSessionId`).
    public var harnessSessionID: String?
    public var cwd: String?
    /// The computer the chat runs on: the Mac's name, or the acpmux peer's.
    public var host: String?
    /// The labeled status fields (`/status`'s).
    public var status: AgentSessionStatus

    public init(name: String?, sessionID: String, harnessSessionID: String?, cwd: String?, host: String?,
                status: AgentSessionStatus) {
        self.name = name
        self.sessionID = sessionID
        self.harnessSessionID = harnessSessionID
        self.cwd = cwd
        self.host = host
        self.status = status
    }

    /// The Mac's Copy Session Details text (CmuxNextAgentPane `AgentChatCopyText.details`), one
    /// labeled line per value it has. The session file paths are left out: acpmux names them
    /// only over the Mac's own socket.
    public var detailsText: String {
        var lines: [String] = []
        if let name, !name.isEmpty { lines.append("Agent name: \(name)") }
        lines.append("Agent identifier: \(sessionID)")
        if let harnessSessionID, !harnessSessionID.isEmpty { lines.append("Harness session ID: \(harnessSessionID)") }
        if let cwd, !cwd.isEmpty { lines.append("CWD: \(cwd)") }
        if let host, !host.isEmpty { lines.append("Host: \(host)") }
        return lines.joined(separator: "\n")
    }
}

/// The chat's lasting grant (`_acpmux/permission_groups` `chatAllowance`).
public struct AgentChatPermissions: Hashable, Sendable {
    /// An Allow for This Chat is in force (made on the Mac: a phone can't make one).
    public var allowedForChat: Bool
    /// Permission groups still waiting on an answer.
    public var openGroups: Int

    public init(allowedForChat: Bool, openGroups: Int) {
        self.allowedForChat = allowedForChat
        self.openGroups = openGroups
    }
}

/// One raw record the phone received for a chat: a row of the Event Inspector (the Mac's
/// Session view of its ACP inspector: "{method} {sessionUpdate} · seq {seq}").
public struct AgentInspectorEvent: Identifiable, Hashable, Sendable {
    /// Arrival order on this phone.
    public let id: Int
    public let seq: Int
    public let at: Date
    /// `in` (from the agent), `out` (to it) or `mux` (acpmux's own).
    public let dir: String
    public let kind: String
    public let method: String?
    /// The `sessionUpdate` of an agent update.
    public let update: String?
    /// The record as it came (encoded only when a person reads it).
    public let record: JSONValue
    /// The record as one compact JSON line, encoded once (filter, export, the byte budget).
    public let line: String

    public init(id: Int, record: JSONValue) {
        self.id = id
        self.record = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        line = (try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        seq = Int(record["seq"]?.numberValue ?? 0)
        at = record["at"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        dir = record["dir"]?.stringValue ?? ""
        kind = record["kind"]?.stringValue ?? ""
        let msg = record["msg"]
        method = msg?["method"]?.stringValue
        update = (msg?["params"]?["update"] ?? msg?["update"])?["sessionUpdate"]?.stringValue
    }

    private init(id: Int, seq: Int, at: Date, dir: String, kind: String, method: String?, update: String?, record: JSONValue, line: String) {
        self.id = id
        self.seq = seq
        self.at = at
        self.dir = dir
        self.kind = kind
        self.method = method
        self.update = update
        self.record = record
        self.line = line
    }

    /// Why a dropped record's body is gone (its detail shows this, as a cut record's shows its cut).
    nonisolated static let droppedNote = "dropped from the newest 500 on iPhone; only its kind and seq are kept"

    /// The row without its body: what a list showing a record the journal dropped keeps (the
    /// same row; its detail says it was dropped).
    var stub: AgentInspectorEvent {
        var kept: [String: JSONValue] = ["cut": .string(Self.droppedNote), "seq": .number(Double(seq)),
                                         "dir": .string(dir), "kind": .string(kind)]
        if let method { kept["method"] = .string(method) }
        if let update { kept["sessionUpdate"] = .string(update) }
        let record = JSONValue.object(kept)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = (try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return AgentInspectorEvent(id: id, seq: seq, at: at, dir: dir, kind: kind, method: method, update: update,
                                   record: record, line: line)
    }

    /// Whether this is a dropped record's row (`stub`).
    var isStub: Bool { record["cut"]?.stringValue == Self.droppedNote }

    /// The row's title, as the Mac's inspector names a record.
    public var title: String {
        var name = method ?? kind
        if let update { name += " \(update)" }
        return seq > 0 ? "\(name) · seq \(seq)" : name
    }

    /// The record as pretty JSON, cut at ``AgentEventJournal/maxCharacters`` (the Mac's
    /// "… cut at {shown} of {total} characters").
    public var json: (text: String, total: Int?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard text.count > AgentEventJournal.maxCharacters else { return (text, nil) }
        return (String(text.prefix(AgentEventJournal.maxCharacters)), text.count)
    }

    /// Whether the filter text matches the row (case-insensitive; its name, kind or body).
    public func matches(_ filter: String) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [title, kind, dir].contains { $0.localizedCaseInsensitiveContains(query) }
            || line.localizedCaseInsensitiveContains(query)
    }
}

/// The newest raw records of one chat, kept while its source lives (bounded).
///
/// Records arrive one by one from the Mac, hundreds a second in a burst. Each is kept at once
/// (Copy and a detail page read the newest), but observers hear of them once per display frame
/// (``nextFrame``), and dropping the oldest costs the rows dropped, not the rows kept.
@MainActor
@Observable
public final class AgentEventJournal {
    /// The most rows kept: the Mac's inspector shows its newest 500.
    public nonisolated static let limit = 500
    /// The most characters of one record's JSON shown.
    public nonisolated static let maxCharacters = 20_000
    /// The most bytes the kept records take (tool output can be hundreds of KB each).
    public nonisolated static let maxBytes = 4 << 20
    /// The most bytes one record keeps: a larger one keeps its kind and seq, not its body.
    public nonisolated static let maxRecordBytes = 256 << 10
    /// What a dropped row's slot holds until the emptied front is reclaimed (its record's memory goes at once).
    nonisolated static let emptied = AgentInspectorEvent(id: -1, record: .null)
    @ObservationIgnored private var bytes = 0

    /// The kept rows, oldest first, from `start`; the slots before it are emptied.
    @ObservationIgnored private var storage: [AgentInspectorEvent] = []
    @ObservationIgnored private var start = 0
    /// The id of `storage[0]` (ids count up by one per record).
    @ObservationIgnored private var baseID = 0
    @ObservationIgnored private var droppedCount = 0
    @ObservationIgnored private var next = 0
    /// What observers read: bumped once per display frame that had records, and by Clear.
    private var revision = 0
    @ObservationIgnored private var publishing: Task<Void, Never>?
    /// Waits for the next display frame (records are published together there). nil publishes
    /// each record at once.
    @ObservationIgnored var nextFrame: (@MainActor () async -> Void)? = AgentEventJournal.defaultNextFrame
    /// Changes published to observers (tests: one per frame, not one per record).
    @ObservationIgnored private(set) var changes = 0
    /// Kept rows moved to drop older ones (tests: dropping costs the rows dropped, not the rows kept).
    @ObservationIgnored private(set) var moved = 0
    /// Bumped by Clear: a memo of the rows starts over.
    @ObservationIgnored private(set) var generation = 0
    /// Called with each record as it is kept, once older ones have dropped for it (a held list
    /// counts every arrival, also those the limit drops before the next frame's read, and keeps
    /// only what the journal keeps).
    @ObservationIgnored private var taps: [Int: @MainActor (AgentInspectorEvent) -> Void] = [:]
    @ObservationIgnored private var nextTap = 0

    /// Calls `each` with every record from now on, until `untap(token)`.
    func tap(_ each: @escaping @MainActor (AgentInspectorEvent) -> Void) -> Int {
        nextTap += 1
        taps[nextTap] = each
        return nextTap
    }

    func untap(_ token: Int) {
        taps[token] = nil
    }

    public init() {}

    /// The kept rows, oldest first (a copy).
    public var events: [AgentInspectorEvent] { Array(rows) }
    /// The kept rows, oldest first, not copied.
    var rows: ArraySlice<AgentInspectorEvent> {
        _ = revision
        return storage[start...]
    }
    /// How many rows are kept.
    public var count: Int {
        _ = revision
        return storage.count - start
    }
    /// Rows dropped for the limit since the last Clear.
    public var dropped: Int {
        _ = revision
        return droppedCount
    }
    /// The id the next record gets.
    var nextID: Int { next }
    /// The oldest kept row's id.
    var firstID: Int { baseID + start }
    /// The bytes the kept records take.
    var keptBytes: Int { bytes }

    /// The kept rows with an id from `id` on, oldest first.
    func events(from id: Int) -> ArraySlice<AgentInspectorEvent> {
        storage[min(max(id - baseID, start), storage.count)...]
    }

    public func record(_ record: JSONValue) {
        var event = AgentInspectorEvent(id: next, record: record)
        if event.line.utf8.count > Self.maxRecordBytes {
            let size = event.line.utf8.count
            var kept: [String: JSONValue] = ["cut": .string("\(size) bytes; only its kind and seq are kept on iPhone")]
            for key in ["seq", "at", "dir", "kind", "sessionId"] { if let value = record[key] { kept[key] = value } }
            event = AgentInspectorEvent(id: next, record: .object(kept))
        }
        storage.append(event)
        bytes += event.line.utf8.count
        next += 1
        // The oldest go first, past the row limit or the byte budget (the newest always stays).
        while storage.count - start > 1, storage.count - start > Self.limit || bytes > Self.maxBytes {
            bytes -= storage[start].line.utf8.count
            storage[start] = Self.emptied
            start += 1
            droppedCount += 1
        }
        // The emptied front is reclaimed in bulk: a kept row moves once per as many drops.
        if start >= 64, start * 2 >= storage.count {
            moved += storage.count - start
            storage.removeFirst(start)
            baseID += start
            start = 0
        }
        // After the drops: a held list counts the record and lets go of what was just dropped.
        for each in taps.values { each(event) }
        changed()
    }

    public func clear() {
        storage = []
        start = 0
        baseID = next
        droppedCount = 0
        bytes = 0
        generation += 1
        publish()
    }

    /// One published change per frame for every record in it.
    private func changed() {
        guard let nextFrame else { return publish() }
        guard publishing == nil else { return }
        publishing = Task { [weak self] in
            await nextFrame()
            self?.publishing = nil
            self?.publish()
        }
    }

    private func publish() {
        revision &+= 1
        changes += 1
    }

    /// The rows as JSON Lines (the Mac's Export).
    public func jsonLines(_ rows: [AgentInspectorEvent]) -> String {
        rows.map(\.line).joined(separator: "\n")
    }
}

/// The Event Inspector's rows for its filter, oldest first (the screen draws them newest first),
/// kept as the journal changes: a record costs one `matches` (none with no filter), a dropped
/// one costs itself, and only a new query looks at every record, once, off the main thread
/// when the records are large. A query's result lands only while it is the newest query.
@MainActor
@Observable
final class EventInspectorRows {
    /// Journals whose kept records take more bytes than this are filtered off the main thread.
    @ObservationIgnored let offMainAbove: Int
    private(set) var query = ""
    /// The query every row matches. While an off-main filter for a new `query` runs, the rows
    /// stay this one's (new records matched against it too), so the list and its copy are one
    /// query's rows, never a mix.
    private(set) var shownQuery = ""
    /// An off-main filter for `query` is running (the screen holds Copy until it lands).
    private(set) var isFiltering = false
    @ObservationIgnored private var matched: [AgentInspectorEvent] = []
    /// The first shown row of `matched` (those before it were dropped).
    @ObservationIgnored private var head = 0
    /// The first journal id not looked at yet.
    @ObservationIgnored private var nextID = 0
    /// The journal's generation these rows are of (-1: none yet).
    @ObservationIgnored private var generation = -1
    @ObservationIgnored private var filtering: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    /// `matches` calls made (tests: the work a record or a query costs).
    @ObservationIgnored private(set) var matchCalls = 0
    /// Whole-journal filters run (one per query).
    @ObservationIgnored private(set) var builds = 0
    /// The queries whose results were shown, in order.
    @ObservationIgnored private(set) var shownQueries: [String] = []
    /// The reader is away from the top (the screen's "N new events" pill): new records stay out
    /// of the rows, and rows the journal drops stay in, so nothing in the list moves while they
    /// read. They land together when the hold ends (the pill, or the reader back at the top).
    @ObservationIgnored private(set) var holding = false
    /// Records that came while holding and match the shown query, oldest first, from `heldHead`.
    /// Bounded by the journal: records it drops leave at once (`compactHeld`), so a long hold
    /// under a stream keeps no dropped bodies; the pill's count is `arrivedWhileHeld`.
    @ObservationIgnored private var held: [AgentInspectorEvent] = []
    @ObservationIgnored private var heldHead = 0
    /// While holding: rows of `matched` before this one the journal dropped, kept as stubs.
    @ObservationIgnored private var stubHead = 0
    /// Rows turned into stubs while holding (tests: a body is let go when its record drops).
    @ObservationIgnored private(set) var stubbed = 0
    /// Stubs in the rows now (dropped records a held list still shows; not counted as kept).
    @ObservationIgnored private var stubsShown = 0
    /// Bumped when a hold ends: the screen draws the held records.
    private var released = 0
    /// Bumped when a query's rows land (at once, or when its off-main filter does): the one
    /// change the list hears of per keystroke. Starting an off-main filter changes nothing the
    /// list draws (its rows stay the shown query's until then).
    private var landed = 0
    /// Held records (the pill's count; read after `rows`, which brings it up to date).
    var heldCount: Int { held.count - heldHead }
    /// Slots in `held`, kept or emptied (tests: bounded by the journal, not by the arrivals).
    var heldStorage: Int { held.count }
    /// The bytes of the records `held` still keeps (tests: at most the journal's). Emptied slots
    /// hold the one shared placeholder (`AgentEventJournal.emptied`), no body of their own.
    var heldBytes: Int { held.reduce(0) { $0 + ($1.id < 0 ? 0 : $1.line.utf8.count) } }
    /// Slots of `held` that are not the shared placeholder but are before the journal's first
    /// kept record (tests: none; a dropped record's body is let go at once).
    func heldDroppedBodies(_ journal: AgentEventJournal) -> Int {
        held.reduce(0) { $0 + ($1.id >= 0 && $1.id < journal.firstID ? 1 : 0) }
    }
    /// Records that arrived while holding and match the shown query, counted as they come and
    /// never lowered when the journal later drops one (the pill's real count; what lands is the
    /// kept ones, `heldCount`).
    @ObservationIgnored private(set) var arrivedWhileHeld = 0
    /// The journal tap that counts arrivals while holding.
    @ObservationIgnored private var tapToken: Int?
    @ObservationIgnored private weak var tappedJournal: AgentEventJournal?
    /// The newest held record's id (where the pill scrolls to).
    var newestHeldID: Int? { heldCount > 0 ? held.last?.id : nil }

    /// The reader left the top (`on`) or came back to it.
    func setHolding(_ on: Bool, journal: AgentEventJournal) {
        guard on != holding else { return }
        if on {
            sync(journal)
            holding = true
            held = []
            heldHead = 0
            arrivedWhileHeld = 0
            stubHead = head
            nextID = journal.nextID
            // Each record as it comes: matched once against the shown query, counted, and held.
            tapToken = journal.tap { [weak self] event in self?.arrived(event) }
            tappedJournal = journal
            return
        }
        holding = false
        if let tapToken { tappedJournal?.untap(tapToken) }
        tapToken = nil
        let first = journal.firstID
        if generation == journal.generation {
            matched += held[heldHead...].filter { $0.id >= first }
        }
        held = []
        heldHead = 0
        arrivedWhileHeld = 0
        stubsShown = 0
        released &+= 1
    }

    /// A record that came while holding.
    private func arrived(_ event: AgentInspectorEvent) {
        guard holding else { return }
        if !shownQuery.isEmpty {
            matchCalls += 1
            guard event.matches(shownQuery) else { return }
        }
        held.append(event)
        arrivedWhileHeld += 1
        // The journal keeps the newest `limit` (and its byte budget): records before its first
        // kept one are gone there, so they go here too, bodies and all.
        if let journal = tappedJournal { compactHeld(first: journal.firstID) }
    }

    /// Lets go of held records the journal no longer keeps: their slots are emptied at once (the
    /// body goes with them), and the emptied front is reclaimed in bulk.
    private func compactHeld(first: Int) {
        while heldHead < held.count, held[heldHead].id < first {
            held[heldHead] = AgentEventJournal.emptied
            heldHead += 1
        }
        // Every 64: `held` stays within the journal's limit plus 64 slots (a move of at most the
        // limit per 64 drops).
        if heldHead >= 64 {
            held.removeFirst(heldHead)
            heldHead = 0
        }
    }

    /// A new query's rows include every record: nothing is held any more.
    private func dropHeld() {
        held = []
        heldHead = 0
        arrivedWhileHeld = 0
        stubsShown = 0
        stubHead = 0
    }

    init(offMainAbove: Int = 64 << 10) {
        self.offMainAbove = offMainAbove
    }

    func setQuery(_ text: String, journal: AgentEventJournal) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != self.query || generation == -1 else { return }
        // Up to date with the last query first: records from here on are matched against the new one.
        sync(journal)
        self.query = query
        token &+= 1
        filtering?.cancel()
        filtering = nil
        isFiltering = false
        let all = journal.rows
        if query.isEmpty || journal.keptBytes <= offMainAbove {
            builds += 1
            if query.isEmpty {
                matched = Array(all)
            } else {
                matchCalls += all.count
                matched = all.filter { $0.matches(query) }
            }
            head = 0
            nextID = journal.nextID
            dropHeld()
            shownQuery = query
            shownQueries.append(query)
            landed &+= 1
            return
        }
        // Off the main thread: the records can be megabytes. Until it lands, the rows shown are
        // the last query's (`shownQuery`), newer records matched against that one as they come.
        isFiltering = true
        let snapshot = Array(all)
        let through = journal.nextID
        let token = token
        let generation = generation
        filtering = Task { [weak self, weak journal] in
            // A newer query cancels this one, and the scan stops with it.
            let scan = Task.detached(priority: .userInitiated) { () -> [AgentInspectorEvent] in
                var out: [AgentInspectorEvent] = []
                for event in snapshot {
                    if Task.isCancelled { return [] }
                    if event.matches(query) { out.append(event) }
                }
                return out
            }
            let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard let self, let journal, self.token == token, !Task.isCancelled else { return }
            self.land(result, through: through, generation: generation, looked: snapshot.count, journal: journal)
        }
    }

    private func land(_ result: [AgentInspectorEvent], through: Int, generation: Int, looked: Int, journal: AgentEventJournal) {
        filtering = nil
        isFiltering = false
        builds += 1
        matchCalls += looked
        shownQuery = query
        if generation == journal.generation {
            // The scan's matches still kept, then the records that came while it ran, matched
            // against this query (they were matched against the shown one).
            let first = journal.firstID
            var rows = result.filter { $0.id >= first }
            let later = journal.events(from: through)
            matchCalls += later.count
            rows += later.filter { $0.matches(query) }
            matched = rows
            head = 0
            nextID = journal.nextID
            dropHeld()
            self.generation = generation
        } else {
            // Cleared while it ran: the records since are matched against this query.
            self.generation = -1
            sync(journal)
        }
        shownQueries.append(query)
        landed &+= 1
    }

    /// The rows matching the query, brought up to the journal (what changed since the last read).
    func rows(_ journal: AgentEventJournal) -> ArraySlice<AgentInspectorEvent> {
        // A query's rows landing and a hold's end redraw the list; a filter starting does not
        // (the "Filtering…" header reads `isFiltering` on its own).
        _ = (landed, released)
        sync(journal)
        return matched[head...]
    }

    /// The kept records that match the shown query, whether shown or held behind the pill (the
    /// header's count: holding still never reads as a filter). Read after `rows`.
    func matchingCount(_ journal: AgentEventJournal) -> Int {
        if shownQuery.isEmpty { return journal.count }
        return max(0, matched.count - head - stubsShown) + heldCount
    }

    /// Returns once no filter is running.
    func settled() async {
        while let filtering { await filtering.value }
    }

    private func sync(_ journal: AgentEventJournal) {
        let count = journal.count
        if generation != journal.generation {
            generation = journal.generation
            matched = []
            head = 0
            nextID = journal.firstID
            dropHeld()
        }
        if holding {
            // Only counted (each record matched once, as it comes); the rows stay as they are.
            let first = journal.firstID
            compactHeld(first: first)
            // A dropped record's row stays (nothing moves under the reader), its body let go.
            while stubHead < matched.count, matched[stubHead].id < first {
                matched[stubHead] = matched[stubHead].stub
                stubHead += 1
                stubbed += 1
                stubsShown += 1
            }
            // The records themselves came through the tap (`arrived`), as they were kept.
            nextID = journal.nextID
            return
        }
        // Dropped from the journal: their slots empty at once, reclaimed in bulk.
        let first = journal.firstID
        while head < matched.count, matched[head].id < first {
            matched[head] = AgentEventJournal.emptied
            head += 1
        }
        if head >= 64, head * 2 >= matched.count {
            matched.removeFirst(head)
            head = 0
        }
        guard nextID < journal.nextID, count > 0 else {
            nextID = max(nextID, journal.nextID)
            return
        }
        for event in journal.events(from: nextID) {
            if shownQuery.isEmpty {
                matched.append(event)
            } else {
                matchCalls += 1
                if event.matches(shownQuery) { matched.append(event) }
            }
        }
        nextID = journal.nextID
    }
}

/// A record's pretty JSON for its detail page, encoded once.
@MainActor
final class EventJSONMemo {
    private var cached: (id: Int, json: (text: String, total: Int?))?
    /// Records encoded (tests: once per record shown, not once per redraw).
    private(set) var encodes = 0

    func json(for event: AgentInspectorEvent) -> (text: String, total: Int?) {
        if let cached, cached.id == event.id { return cached.json }
        encodes += 1
        let json = event.json
        cached = (event.id, json)
        return json
    }
}

/// A chat's recorded transcript for Replay Conversation (the Mac's `webviews/src/replay`):
/// each record's events at its replay time, the recorded clock with every gap longer than
/// ``idleGap`` cut to it.
public struct AgentReplayRecording: Sendable {
    public struct Step: Sendable {
        /// Seconds from the start of the replay.
        public var time: TimeInterval
        public var events: [AgentSessionEvent]
        /// The record starts a tool call (the scrubber's ticks, Previous/Next tool call).
        public var isToolCall: Bool

        public init(time: TimeInterval, events: [AgentSessionEvent], isToolCall: Bool) {
            self.time = time
            self.events = events
            self.isToolCall = isToolCall
        }
    }

    /// The longest pause kept (the Mac's `IDLE_GAP_MS`).
    public static let idleGap: TimeInterval = 2
    public var steps: [Step]
    /// The chat has more records than the replay read.
    public var truncated: Bool

    public init(steps: [Step], truncated: Bool) {
        self.steps = steps
        self.truncated = truncated
    }

    public var duration: TimeInterval { steps.last?.time ?? 0 }

    /// Steps from records at their wall-clock times: the first at 0, each later one after the
    /// gap before it, at most ``idleGap``.
    public static func build(_ records: [(at: Date, events: [AgentSessionEvent], isToolCall: Bool)], truncated: Bool) -> AgentReplayRecording {
        var steps: [Step] = []
        var time: TimeInterval = 0
        var last: Date?
        for record in records where !record.events.isEmpty {
            if let last { time += min(max(0, record.at.timeIntervalSince(last)), idleGap) }
            last = record.at
            steps.append(Step(time: time, events: record.events, isToolCall: record.isToolCall))
        }
        return AgentReplayRecording(steps: steps, truncated: truncated)
    }

    /// How many steps have played at `time`.
    public func played(at time: TimeInterval) -> Int {
        var low = 0, high = steps.count
        while low < high {
            let mid = (low + high) / 2
            if steps[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The tool call before `time` (one that started within `grace` of it counts as the one
    /// playing, so Previous goes to the call before it), or nil.
    public func previousToolCall(before time: TimeInterval, grace: TimeInterval = 0.75) -> TimeInterval? {
        steps.last { $0.isToolCall && $0.time < time - grace }?.time
    }

    public func nextToolCall(after time: TimeInterval) -> TimeInterval? {
        steps.first { $0.isToolCall && $0.time > time + 0.001 }?.time
    }

    /// "m:ss".
    public static func clock(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension AgentSessionSource {
    public func sessionDetails() async throws -> AgentSessionDetails {
        throw AgentFeatureUnavailable(String(localized: "Session details are unavailable for this chat."))
    }

    public func bookmarks() async throws -> [Int] { [] }

    public func setBookmark(seq: Int, bookmarked: Bool) async throws -> [Int] {
        throw AgentFeatureUnavailable(String(localized: "This chat can't keep bookmarks."))
    }

    public func chatPermissions() async throws -> AgentChatPermissions {
        throw AgentFeatureUnavailable(String(localized: "Permissions are unavailable for this chat."))
    }

    public func revokeChatPermission() async throws {
        throw AgentFeatureUnavailable(String(localized: "Permissions are unavailable for this chat."))
    }

    public func refreshPermissions() {}

    public var eventJournal: AgentEventJournal? { nil }

    public var isReadOnly: Bool { false }

    public func replayRecording() async throws -> AgentReplayRecording {
        throw AgentFeatureUnavailable(String(localized: "This chat has no recorded history to replay."))
    }
}

/// The Event Inspector's "N new events" pill: the records that arrived while the reader was away
/// from the top, exactly up to the journal's limit, then "500+" (the journal keeps only its newest
/// ``AgentEventJournal/limit``, so a larger count is "more than" it).
struct NewEventsPill: Equatable {
    /// Records that arrived and match the shown query.
    let arrived: Int
    /// The journal's limit (its one source).
    var cap: Int = AgentEventJournal.limit

    /// More arrived than the journal keeps.
    var isOver: Bool { arrived > cap }
    /// The number the pill shows: exact, or the cap with "+".
    var shown: Int { min(arrived, cap) }

    /// "120 new events", or "500+ new events".
    var text: String {
        isOver
            ? String(localized: "mobile.agentChat.inspector.newEventsOver \(cap)", bundle: .module)
            : String(localized: "mobile.agentChat.inspector.newEvents \(arrived)", bundle: .module)
    }

    /// What VoiceOver reads: "120 new events", or "More than 500 new events".
    var accessibilityText: String {
        isOver
            ? String(localized: "mobile.agentChat.inspector.newEventsOver.accessibility \(cap)", bundle: .module)
            : text
    }
}
