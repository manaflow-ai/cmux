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
    /// The bytes of ``line``, counted from the record without encoding it (the byte budget).
    public let size: Int

    public init(id: Int, record: JSONValue) {
        self.id = id
        self.record = record
        size = record.compactJSONSize
        seq = Int(record["seq"]?.numberValue ?? 0)
        at = record["at"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        dir = record["dir"]?.stringValue ?? ""
        kind = record["kind"]?.stringValue ?? ""
        let msg = record["msg"]
        method = msg?["method"]?.stringValue
        update = (msg?["params"]?["update"] ?? msg?["update"])?["sessionUpdate"]?.stringValue
    }

    /// The record as one compact JSON line (filter, export), encoded on each read: the
    /// inspector reads it through ``AgentEventJournal/line(of:)``, which encodes each row once,
    /// only while the inspector is open.
    public var line: String { Self.encodeLine(record) }

    /// The compact JSON line of `record` (sorted keys, slashes as they are).
    static func encodeLine(_ record: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

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
        matches(filter, line: line)
    }

    /// ``matches(_:)`` with the row's line given (``AgentEventJournal/line(of:)``): read only
    /// when the name, kind and direction don't match.
    public func matches(_ filter: String, line: @autoclosure () -> String) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [title, kind, dir].contains { $0.localizedCaseInsensitiveContains(query) }
            || line().localizedCaseInsensitiveContains(query)
    }
}

extension JSONValue {
    /// The bytes of this value as compact JSON from `JSONEncoder` (`.sortedKeys`,
    /// `.withoutEscapingSlashes`), counted without encoding: a walk over the value and one pass
    /// over each string's UTF-8 for the characters JSON escapes. A number counts as the
    /// encoder writes it (its shortest form, an integral one without ".0").
    public var compactJSONSize: Int {
        switch self {
        case .null: return 4
        case .bool(let value): return value ? 4 : 5
        case .number(let value):
            guard value.isFinite else { return 0 }
            var text = "\(value)"
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text.utf8.count
        case .string(let value): return Self.quotedSize(value)
        case .array(let values):
            return 2 + max(0, values.count - 1) + values.reduce(0) { $0 + $1.compactJSONSize }
        case .object(let members):
            // `{` `}`, a comma between members, and each `"key":value`.
            return 2 + max(0, members.count - 1)
                + members.reduce(0) { $0 + Self.quotedSize($1.key) + 1 + $1.value.compactJSONSize }
        }
    }

    /// A JSON string's bytes with its quotes: `"` and `\` and the short control escapes (\b \t
    /// \n \f \r) take two, any other control character six (\u00XX).
    static func quotedSize(_ string: String) -> Int {
        var size = 2
        for byte in string.utf8 {
            switch byte {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: size += 2
            case 0x00..<0x20: size += 6
            default: size += 1
            }
        }
        return size
    }
}

/// The newest raw records of one chat, kept while its source lives (bounded). A record is
/// kept as it came: its JSON line is encoded only when the inspector reads it (its filter,
/// Copy as JSON Lines), at most once per row, so a chat whose inspector stays closed (almost
/// every chat) encodes nothing.
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
    @ObservationIgnored private var bytes = 0

    public private(set) var events: [AgentInspectorEvent] = []
    /// Rows dropped for the limit since the last Clear.
    public private(set) var dropped = 0
    @ObservationIgnored private var next = 0
    /// The rows' JSON lines encoded so far, by row id (only while the inspector reads them).
    @ObservationIgnored private var lines: [Int: String] = [:]
    /// JSON lines encoded (tests and measurements): the inspector's reads only.
    @ObservationIgnored public private(set) var linesEncoded = 0

    public init() {}

    public func record(_ record: JSONValue) {
        var event = AgentInspectorEvent(id: next, record: record)
        if event.size > Self.maxRecordBytes {
            let size = event.size
            var kept: [String: JSONValue] = ["cut": .string("\(size) bytes; only its kind and seq are kept on iPhone")]
            for key in ["seq", "at", "dir", "kind", "sessionId"] { if let value = record[key] { kept[key] = value } }
            event = AgentInspectorEvent(id: next, record: .object(kept))
        }
        events.append(event)
        bytes += event.size
        next += 1
        // The oldest go first, past the row limit or the byte budget (the newest always stays).
        var over = 0
        var kept = bytes
        while over < events.count - 1, events.count - over > Self.limit || kept > Self.maxBytes {
            kept -= events[over].size
            over += 1
        }
        if over > 0 {
            bytes = kept
            if !lines.isEmpty { for event in events[..<over] { lines[event.id] = nil } }
            events.removeFirst(over)
            dropped += over
        }
    }

    public func clear() {
        events = []
        dropped = 0
        bytes = 0
        lines = [:]
    }

    /// The row's compact JSON line, encoded the first time the inspector reads it.
    public func line(of event: AgentInspectorEvent) -> String {
        if let line = lines[event.id] { return line }
        let line = AgentInspectorEvent.encodeLine(event.record)
        linesEncoded += 1
        lines[event.id] = line
        return line
    }

    /// The rows the inspector's filter keeps, oldest first.
    public func rows(matching filter: String) -> [AgentInspectorEvent] {
        events.filter { event in event.matches(filter, line: line(of: event)) }
    }

    /// Encodes the lines of the rows not encoded yet off the main actor, so the inspector's
    /// first filter or export reads them from memory (up to ``maxBytes`` of JSON: too much to
    /// encode on the main actor). The inspector calls it when it opens.
    public func prepareLines() async {
        let pending = events.filter { lines[$0.id] == nil }.map { (id: $0.id, record: $0.record) }
        guard !pending.isEmpty else { return }
        let encoded = await Task.detached(priority: .userInitiated) {
            pending.map { (id: $0.id, line: AgentInspectorEvent.encodeLine($0.record)) }
        }.value
        // Rows dropped or cleared meanwhile are not kept.
        let kept = Set(events.map(\.id))
        for row in encoded where kept.contains(row.id) && lines[row.id] == nil {
            lines[row.id] = row.line
            linesEncoded += 1
        }
    }

    /// The rows as JSON Lines (the Mac's Export).
    public func jsonLines(_ rows: [AgentInspectorEvent]) -> String {
        rows.map { line(of: $0) }.joined(separator: "\n")
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
