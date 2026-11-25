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

    public init() {}

    public func record(_ record: JSONValue) {
        var event = AgentInspectorEvent(id: next, record: record)
        if event.line.utf8.count > Self.maxRecordBytes {
            let size = event.line.utf8.count
            var kept: [String: JSONValue] = ["cut": .string("\(size) bytes; only its kind and seq are kept on iPhone")]
            for key in ["seq", "at", "dir", "kind", "sessionId"] { if let value = record[key] { kept[key] = value } }
            event = AgentInspectorEvent(id: next, record: .object(kept))
        }
        events.append(event)
        bytes += event.line.utf8.count
        next += 1
        // The oldest go first, past the row limit or the byte budget (the newest always stays).
        var over = 0
        var kept = bytes
        while over < events.count - 1, events.count - over > Self.limit || kept > Self.maxBytes {
            kept -= events[over].line.utf8.count
            over += 1
        }
        if over > 0 {
            bytes = kept
            events.removeFirst(over)
            dropped += over
        }
    }

    public func clear() {
        events = []
        dropped = 0
        bytes = 0
    }

    /// The rows as JSON Lines (the Mac's Export).
    public func jsonLines(_ rows: [AgentInspectorEvent]) -> String {
        rows.map(\.line).joined(separator: "\n")
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
    /// Speeds the speed button steps through, slowest first (the Mac's `REPLAY_SPEEDS`).
    public static let speeds: [Double] = [0.5, 1, 2, 4, 10, 16]
    /// A replay starts at 10x, like a video scrubbed fast (the Mac's `DEFAULT_REPLAY_SPEED`; Leo,
    /// 2026-11-19: "Scrub a chat's history like a video at 10x, with the files and commands it touched").
    public static let defaultSpeed: Double = 10
    public let steps: [Step]
    /// The chat has more records than the replay read.
    public var truncated: Bool
    /// What the tool calls touched, in the order the calls started (the Mac's `touches`).
    public let touches: [AgentReplayTouch]

    public init(steps: [Step], truncated: Bool) {
        self.steps = steps
        self.truncated = truncated
        self.touches = AgentReplayTouch.touches(of: steps)
    }

    /// How many of ``touches`` started within the first `played` steps (the Mac's `touchesThrough`).
    public func touchesThrough(played: Int) -> Int {
        var low = 0, high = touches.count
        while low < high {
            let mid = (low + high) / 2
            if touches[mid].step < played { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The files in `touches`, each once, in first-touch order: edited once a call edited it
    /// without failing (the Mac's `touchedFiles`).
    public static func touchedFiles(_ touches: some Sequence<AgentReplayTouch>) -> [AgentReplayTouchedFile] {
        var files: [AgentReplayTouchedFile] = []
        var index: [String: Int] = [:]
        for touch in touches where touch.kind == .file {
            let edited = touch.verb == .edit && !touch.failed
            if let at = index[touch.text] {
                files[at].edited = files[at].edited || edited
                files[at].last = touch
            } else {
                index[touch.text] = files.count
                files.append(AgentReplayTouchedFile(path: touch.text, edited: edited, last: touch))
            }
        }
        return files
    }

    /// A path as the list shows it: from the chat's folder when it is inside it (the Mac's `shownPath`).
    public static func shownPath(_ path: String, cwd: String? = nil) -> String {
        guard var folder = cwd else { return path }
        while folder.hasSuffix("/") { folder.removeLast() }
        guard !folder.isEmpty, path.hasPrefix(folder + "/") else { return path }
        return String(path.dropFirst(folder.count + 1))
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

/// A file a tool call read or edited, or a command it ran, at the call's start: a row of the
/// replay's Files and Commands (the Mac's `ReplayTouch`, replay/timeline.ts).
public struct AgentReplayTouch: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case file, command }
    public enum Verb: Hashable, Sendable { case read, edit, run }

    /// Its place in ``AgentReplayRecording/touches``.
    public var id: Int
    /// The step the call started at (the Mac's `seq`).
    public var step: Int
    public var time: TimeInterval
    public var kind: Kind
    public var verb: Verb
    /// The path, or the command line.
    public var text: String
    public var failed: Bool

    public init(id: Int, step: Int, time: TimeInterval, kind: Kind, verb: Verb, text: String, failed: Bool) {
        self.id = id
        self.step = step
        self.time = time
        self.kind = kind
        self.verb = verb
        self.text = text
        self.failed = failed
    }

    /// A tool call folded across its `tool_call` and `tool_call_update`s as the Mac's
    /// `mergeToolItem` folds it, and where it started.
    private struct Call {
        var step: Int
        var time: TimeInterval
        var title: String
        var kind: ACPToolCall.Kind
        var status: ACPToolCall.Status
        var locations: [ACPToolCall.Location]
        var rawInput: JSONValue?
        var command: String?

        /// ACP sends `{}` when an update changes only status or output: the call keeps its input.
        static func input(_ value: JSONValue?) -> JSONValue? {
            switch value {
            case nil, .null?: nil
            case .object(let object)? where object.isEmpty: nil
            default: value
            }
        }

        mutating func merge(title: String?, kind: ACPToolCall.Kind?, status: ACPToolCall.Status?,
                            locations: [ACPToolCall.Location]?, rawInput: JSONValue?) {
            if let title, !title.isEmpty { self.title = title }
            if let kind { self.kind = kind }
            if let status { self.status = status }
            if let locations { self.locations = locations }
            if let input = Self.input(rawInput) {
                self.rawInput = input
                command = AgentReplayTouch.shellCommand(input) ?? command
            }
        }
    }

    /// The files and commands each call touched: a shell call's command line, a read's or an
    /// edit's files (``editedPaths(rawInput:locations:title:)``). Other calls (search, fetch,
    /// think) touch nothing listed. The Mac's `touchesOf`.
    static func touches(of steps: [AgentReplayRecording.Step]) -> [AgentReplayTouch] {
        var order: [String] = []
        var calls: [String: Call] = [:]
        func fold(_ event: AgentSessionEvent, step: Int, time: TimeInterval) {
            switch event {
            case .batch(let events):
                for event in events { fold(event, step: step, time: time) }
            case .update(.toolCall(let call)):
                if calls[call.id] == nil {
                    order.append(call.id)
                    var folded = Call(step: step, time: time, title: call.title.isEmpty ? call.id : call.title,
                                      kind: call.kind, status: call.status, locations: call.locations)
                    folded.merge(title: nil, kind: nil, status: nil, locations: nil, rawInput: call.rawInput)
                    calls[call.id] = folded
                } else {
                    calls[call.id]?.merge(title: call.title, kind: call.kind == .other ? nil : call.kind, status: call.status,
                                          locations: call.locations.isEmpty ? nil : call.locations, rawInput: call.rawInput)
                }
            case .update(.toolCallUpdate(let update)):
                if calls[update.toolCallId] == nil {
                    order.append(update.toolCallId)
                    calls[update.toolCallId] = Call(step: step, time: time, title: update.toolCallId, kind: .other,
                                                    status: .inProgress, locations: [])
                }
                calls[update.toolCallId]?.merge(title: update.title, kind: update.kind, status: update.status,
                                                locations: update.locations, rawInput: update.rawInput)
            default:
                break
            }
        }
        for (index, step) in steps.enumerated() {
            for event in step.events { fold(event, step: index, time: step.time) }
        }
        var touches: [AgentReplayTouch] = []
        func add(_ call: Call, _ kind: Kind, _ verb: Verb, _ text: String) {
            touches.append(AgentReplayTouch(id: touches.count, step: call.step, time: call.time, kind: kind, verb: verb,
                                            text: text, failed: call.status == .failed))
        }
        for id in order {
            guard let call = calls[id] else { continue }
            if let command = call.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                add(call, .command, .run, command)
            } else if [.read, .edit, .delete, .move].contains(call.kind) {
                for path in editedPaths(rawInput: call.rawInput, locations: call.locations, title: call.title) {
                    add(call, .file, call.kind == .read ? .read : .edit, path)
                }
            }
        }
        return touches
    }

    // MARK: The Mac's readers (webviews direct.ts `shellCommand`, toolPaths.ts `editedPaths`)

    /// The command line a shell call ran, from `rawInput.command`: a string, or an argv array. An
    /// argv that runs a script through a shell (`zsh -lc "cd x && bun test"`) shows the script;
    /// otherwise a part with spaces or quotes is single-quoted, so the line reads as typed.
    static func shellCommand(_ rawInput: JSONValue?) -> String? {
        guard let command = rawInput?["command"] else { return nil }
        if let string = command.stringValue { return string }
        guard let values = command.arrayValue, !values.isEmpty else { return nil }
        let argv = values.compactMap(\.stringValue)
        guard argv.count == values.count else { return nil }
        let program = argv[0].split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if argv.count == 3, ["sh", "bash", "zsh", "dash", "fish"].contains(program), argv[1] == "-c" || argv[1] == "-lc" {
            return argv[2]
        }
        return argv.map { part in
            let plain = !part.isEmpty && part.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_@%+=:,./-".unicodeScalars.contains(scalar))
            }
            return plain ? part : "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Field names that hold the edited file, in the order the harnesses use them.
    static let pathKeys = ["file_path", "filePath", "notebook_path", "notebookPath", "absolute_path", "path", "target_file"]
    /// Field names that hold an apply_patch body.
    static let patchKeys = ["patch", "patchText", "input"]

    /// The paths a file call read or edited, in first-seen order without repeats: its input's
    /// path fields (each harness's shape: Claude Code's `file_path`, Codex's `apply_patch` and
    /// `changes`, opencode's `filePath`, pi's `path`), else its locations, else a path in its title.
    static func editedPaths(rawInput: JSONValue?, locations: [ACPToolCall.Location], title: String) -> [String] {
        var found: [String] = []
        func add(_ value: String?) {
            guard let path = value?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                  path.utf8.count <= 4096, !path.contains("\n"), !found.contains(path) else { return }
            found.append(path)
        }
        func patchPaths(_ text: String?) {
            guard let text, text.contains("*** ") else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                    add(String(line.dropFirst(prefix.count)))
                }
            }
            let move = "*** Move to: "
            for line in lines where line.hasPrefix(move) { add(String(line.dropFirst(move.count))) }
        }
        if case .object(let input)? = rawInput {
            for key in pathKeys { add(input[key]?.stringValue) }
            for key in patchKeys { patchPaths(input[key]?.stringValue) }
            if let argv = input["command"]?.arrayValue, argv.first?.stringValue == "apply_patch" {
                for part in argv { patchPaths(part.stringValue) }
            } else if let command = input["command"]?.stringValue, command.contains("*** Begin Patch") {
                patchPaths(command)
            }
            switch input["changes"] {
            case .array(let changes)?: for change in changes { add(change["path"]?.stringValue) }
            case .object(let changes)?: for path in changes.keys.sorted() { add(path) }
            default: break
            }
            for edit in input["edits"]?.arrayValue ?? [] {
                for key in pathKeys { add(edit[key]?.stringValue) }
            }
        }
        if found.isEmpty { for location in locations { add(location.path) } }
        if found.isEmpty { add(titlePath(title)) }
        return found
    }

    /// A path in a title after its verb ("Read src/a.ts"), if the rest looks like one.
    static func titlePath(_ title: String) -> String? {
        var rest = title.split(whereSeparator: \.isWhitespace).dropFirst().joined(separator: " ")
        if rest.hasPrefix("`") { rest.removeFirst() }
        if rest.hasSuffix("`") { rest.removeLast() }
        return looksLikePath(rest)
    }

    /// `text` if it reads as a path: it has a `/`, or it is a file name with an extension.
    static func looksLikePath(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains(where: { "\n{}\"".contains($0) }) else { return nil }
        if text.contains("/") { return text }
        let allowed = text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
        }
        guard allowed, let dot = text.lastIndex(of: "."), dot > text.startIndex else { return nil }
        let ext = text[text.index(after: dot)...]
        let isExtension = (1...12).contains(ext.count) && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        return isExtension ? text : nil
    }
}

/// A file in the replay's Files list: once, edited once any call changed it (the Mac's `TouchedFile`).
public struct AgentReplayTouchedFile: Hashable, Sendable {
    public var path: String
    public var edited: Bool
    /// The latest call that touched it: where a tap seeks.
    public var last: AgentReplayTouch
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
