import Foundation

// ACP data as acpmux relays it (cmux-tui/crates/acpmux/docs/acpmux-schema.json,
// agent `session/update` notifications and acpmux mux records). Field names in
// `CodingKeys` match the wire exactly so the link-backed source can decode frames
// straight into these types.

/// Any JSON value (rawInput, rawOutput, _meta).
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

/// ACP ContentBlock (subset the transcript renders).
public enum ACPContentBlock: Hashable, Sendable, Codable {
    case text(String)
    case image(mimeType: String, data: String)
    case resourceLink(uri: String, name: String)

    private enum CodingKeys: String, CodingKey { case type, text, mimeType, data, uri, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "image":
            self = .image(mimeType: try container.decode(String.self, forKey: .mimeType), data: try container.decode(String.self, forKey: .data))
        case "resource_link":
            self = .resourceLink(uri: try container.decode(String.self, forKey: .uri), name: try container.decodeIfPresent(String.self, forKey: .name) ?? "")
        default:
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mimeType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(data, forKey: .data)
        case .resourceLink(let uri, let name):
            try container.encode("resource_link", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encode(name, forKey: .name)
        }
    }

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

public struct ACPToolCall: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case read, edit, delete, move, search, execute, think, fetch, other
        case switchMode = "switch_mode"
        case fileChange

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public enum Status: String, Hashable, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    public enum Content: Hashable, Sendable, Codable {
        case content(ACPContentBlock)
        case diff(path: String, oldText: String?, newText: String)
        case terminal(terminalId: String)

        private enum CodingKeys: String, CodingKey { case type, content, path, oldText, newText, terminalId }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "diff":
                self = .diff(
                    path: try container.decode(String.self, forKey: .path),
                    oldText: try container.decodeIfPresent(String.self, forKey: .oldText),
                    newText: try container.decode(String.self, forKey: .newText)
                )
            case "terminal":
                self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
            default:
                self = .content(try container.decode(ACPContentBlock.self, forKey: .content))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .content(let block):
                try container.encode("content", forKey: .type)
                try container.encode(block, forKey: .content)
            case .diff(let path, let oldText, let newText):
                try container.encode("diff", forKey: .type)
                try container.encode(path, forKey: .path)
                try container.encodeIfPresent(oldText, forKey: .oldText)
                try container.encode(newText, forKey: .newText)
            case .terminal(let terminalId):
                try container.encode("terminal", forKey: .type)
                try container.encode(terminalId, forKey: .terminalId)
            }
        }
    }

    public struct Location: Hashable, Sendable, Codable {
        public var path: String
        public var line: Int?

        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var status: Status
    public var content: [Content]
    public var locations: [Location]
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    /// Client-side timing (first event, first terminal status).
    public var startedAt: Date?
    public var endedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id = "toolCallId", title, kind, status, content, locations, rawInput, rawOutput
    }

    public init(
        id: String, title: String, kind: Kind, status: Status = .inProgress, content: [Content] = [],
        locations: [Location] = [], rawInput: JSONValue? = nil, rawOutput: JSONValue? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .inProgress
        content = try container.decodeIfPresent([Content].self, forKey: .content) ?? []
        locations = try container.decodeIfPresent([Location].self, forKey: .locations) ?? []
        rawInput = try container.decodeIfPresent(JSONValue.self, forKey: .rawInput)
        rawOutput = try container.decodeIfPresent(JSONValue.self, forKey: .rawOutput)
    }

    /// Applies a `tool_call_update`: only present fields change; `content` replaces.
    public mutating func apply(_ update: ACPToolCallUpdate) {
        if let title = update.title { self.title = title }
        if let kind = update.kind { self.kind = kind }
        if let status = update.status { self.status = status }
        if let content = update.content { self.content = content }
        if let locations = update.locations { self.locations = locations }
        if let rawInput = update.rawInput { self.rawInput = rawInput }
        if let rawOutput = update.rawOutput { self.rawOutput = rawOutput }
    }

    /// The shell command for execute calls: `rawInput.command` as a string or argv (`sh -lc script` shows the script).
    public var command: String? {
        guard let command = rawInput?["command"] else { return nil }
        if let string = command.stringValue { return string }
        if let argv = command.arrayValue?.compactMap(\.stringValue) {
            if argv.count == 3, ["sh", "bash", "zsh"].contains(argv[0]), argv[1].hasPrefix("-") { return argv[2] }
            return argv.joined(separator: " ")
        }
        return nil
    }

    public var exitCode: Int? {
        (rawOutput?["exit_code"] ?? rawOutput?["exitCode"])?.numberValue.map { Int($0) }
    }

    public var isFailed: Bool { status == .failed || (exitCode ?? 0) != 0 }
    public var isRunning: Bool { status == .pending || status == .inProgress }

    public var diffs: [(path: String, oldText: String?, newText: String)] {
        content.compactMap {
            if case .diff(let path, let oldText, let newText) = $0 { return (path, oldText, newText) }
            return nil
        }
    }

    public var outputText: String {
        content.compactMap {
            if case .content(let block) = $0 { return block.text }
            return nil
        }.joined(separator: "\n")
    }
}

/// `tool_call_update`: every field optional.
public struct ACPToolCallUpdate: Hashable, Sendable, Codable {
    public var toolCallId: String
    public var title: String?
    public var kind: ACPToolCall.Kind?
    public var status: ACPToolCall.Status?
    public var content: [ACPToolCall.Content]?
    public var locations: [ACPToolCall.Location]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        toolCallId: String, title: String? = nil, kind: ACPToolCall.Kind? = nil, status: ACPToolCall.Status? = nil,
        content: [ACPToolCall.Content]? = nil, locations: [ACPToolCall.Location]? = nil, rawInput: JSONValue? = nil, rawOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

public struct ACPPlanEntry: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    public var priority: String
    public var status: Status

    public init(content: String, priority: String = "medium", status: Status = .pending) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

public struct ACPPermissionOption: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
    }

    public var id: String
    public var name: String
    public var kind: Kind

    private enum CodingKeys: String, CodingKey { case id = "optionId", name, kind }

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isAllow: Bool { kind == .allowOnce || kind == .allowAlways }

    /// The button's words, as the Mac's agent pane says them ("Allow once", "Deny"); an
    /// option with its own words ("Answer", "Allow and run it") keeps them.
    public var phoneLabel: String {
        switch (kind, name.lowercased()) {
        case (.allowOnce, "allow"), (.allowOnce, "allow once"), (.allowOnce, ""): "Allow once"
        case (.rejectOnce, "reject"), (.rejectOnce, "deny"), (.rejectOnce, "reject once"), (.rejectOnce, ""): "Deny"
        default: name
        }
    }
}

/// `session/request_permission` as acpmux relays it (`_acpmux/permission_pending`).
public struct ACPPermissionRequest: Hashable, Sendable, Identifiable {
    public var id: String
    public var toolCall: ACPToolCall
    public var options: [ACPPermissionOption]
    public var cwd: String?

    public init(id: String, toolCall: ACPToolCall, options: [ACPPermissionOption], cwd: String? = nil) {
        self.id = id
        self.toolCall = toolCall
        self.options = options
        self.cwd = cwd
    }

    /// What a phone may answer: allow once or deny once. acpmux refuses a lasting grant
    /// (`allow_always`, `reject_always`) from a paired device (`remote.lasting_grant_refused`),
    /// so offering one cost a Face ID and then failed. A request with no single-use option
    /// keeps its options, so acpmux's refusal says why.
    public var phoneOptions: [ACPPermissionOption] {
        // Without a single-use Allow the options stay as the agent sent them (acpmux's
        // refusal of a lasting grant then says why), rather than a lone Deny.
        guard options.contains(where: { $0.kind == .allowOnce }) else { return options }
        return options.filter { $0.kind == .allowOnce || $0.kind == .rejectOnce }
    }
}

public struct ACPAvailableCommand: Hashable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var hint: String?

    public init(name: String, description: String, hint: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
    }
}

/// `configOptions` entry (`session/set_config_option`).
public struct ACPConfigOption: Hashable, Sendable, Codable, Identifiable {
    public struct Value: Hashable, Sendable, Codable {
        public var value: String
        public var name: String?
        public var description: String?

        public init(value: String, name: String? = nil, description: String? = nil) {
            self.value = value
            self.name = name
            self.description = description
        }
    }

    public var id: String
    public var name: String?
    public var category: String?
    public var currentValue: String?
    public var options: [Value]

    public init(id: String, name: String? = nil, category: String? = nil, currentValue: String? = nil, options: [Value]) {
        self.id = id
        self.name = name
        self.category = category
        self.currentValue = currentValue
        self.options = options
    }

    /// The effort picker reads `category == "thought_level"` or id `effort` / `reasoning_effort`.
    public var isEffort: Bool { category == "thought_level" || id == "effort" || id == "reasoning_effort" }
}

public struct ACPModelInfo: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ACPMode: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

extension ACPMode {
    /// Modes a phone may switch an agent to: those that ask before each change (Claude Code's
    /// `default` and `plan`, the Codex bridge's `ask`). The Mac's cmux-mobile-host refuses any other
    /// (`acpmux_policy.rs` `PHONE_MODES`) unless this phone's Full-access setting covers it.
    public static let phoneModeIDs: Set<String> = ["default", "plan", "ask"]

    /// `modes` a phone may pick, plus the current one (shown checked, so a chat the Mac moved
    /// to another mode still says which). `fullAccess`: this phone's Full-access setting on the
    /// Mac covers it (acpmux `initialize` `_meta.acpmux.fullAccess`), so the harness's Full
    /// access mode (`bypassPermissions`, `agent-full-access`) is offered too. acpmux still
    /// decides each switch by that setting; the menu only stops hiding the mode.
    public static func phoneChoices(_ modes: [ACPMode], current: String?, fullAccess: Bool = false) -> [ACPMode] {
        modes.filter { phoneModeIDs.contains($0.id) || $0.id == current || (fullAccess && isFullAccess($0.id)) }
    }

    /// The markers of cmux-tui/spec/full-access-modes.json, the rule acpmux (`hub/start_mode.rs`)
    /// and the Mac (`AgentPaneModeConfirmation`) apply.
    static let fullAccessMarkers = ["bypass", "fullaccess", "yolo", "dangerous", "autoapprove", "skippermissions"]

    /// A mode that skips every approval: lowercased, without `-`, `_` or spaces, it contains a marker.
    public static func isFullAccess(_ id: String) -> Bool {
        let folded = String(id.lowercased().filter { !"-_ ".contains($0) })
        return fullAccessMarkers.contains { folded.contains($0) }
    }
}

/// Agent `session/update` notifications (discriminator `sessionUpdate`).
public enum ACPSessionUpdate: Hashable, Sendable {
    case agentMessageChunk(text: String, messageId: String?)
    case agentThoughtChunk(text: String)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableCommands([ACPAvailableCommand])
    case currentMode(String)
    case configOptions([ACPConfigOption])
    case usage(used: Int, size: Int)
    /// `session_info_update`: the agent named the session (ACP session title).
    case sessionInfo(title: String?)
}

extension ACPSessionUpdate: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, content, messageId, entries, availableCommands, currentModeId, configOptions, used, size, toolCallId, title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "agent_message_chunk":
            let block = try container.decode(ACPContentBlock.self, forKey: .content)
            self = .agentMessageChunk(text: block.text ?? "", messageId: try container.decodeIfPresent(String.self, forKey: .messageId))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(text: try container.decode(ACPContentBlock.self, forKey: .content).text ?? "")
        case "tool_call":
            self = .toolCall(try ACPToolCall(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ACPToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(try container.decode([ACPPlanEntry].self, forKey: .entries))
        case "available_commands_update":
            let commands = try container.decode([ACPAvailableCommand].self, forKey: .availableCommands)
            self = .availableCommands(commands.map { var c = $0; if c.name.hasPrefix("/") { c.name.removeFirst() }; return c })
        case "current_mode_update":
            self = .currentMode(try container.decode(String.self, forKey: .currentModeId))
        case "config_option_update":
            self = .configOptions(try container.decode([ACPConfigOption].self, forKey: .configOptions))
        case "usage_update":
            self = .usage(used: try container.decode(Int.self, forKey: .used), size: try container.decode(Int.self, forKey: .size))
        case "session_info_update":
            self = .sessionInfo(title: try container.decodeIfPresent(String.self, forKey: .title))
        default:
            throw DecodingError.dataCorruptedError(forKey: .sessionUpdate, in: container, debugDescription: "Unhandled sessionUpdate \(kind)")
        }
    }
}
