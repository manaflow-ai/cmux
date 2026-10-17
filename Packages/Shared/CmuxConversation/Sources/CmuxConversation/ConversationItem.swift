public import Foundation

/// The normalized kind of one ordered conversation item.
public enum ConversationItemKind: Hashable, Sendable, Codable {
    /// User or assistant message text.
    case message
    /// Provider reasoning summary.
    case reasoning
    /// A plan or progress update.
    case plan
    /// A tool invocation.
    case tool
    /// A tool result.
    case result
    /// A provider error.
    case error
    /// A child or subagent relationship.
    case child
    /// A file or diff update.
    case files
    /// A binary or downloadable artifact reference.
    case artifact
    /// Usage or model metadata.
    case usage
    /// A provider item not recognized by this client.
    case unknown(String)

    public var rawValue: String {
        switch self { case .message: "message"; case .reasoning: "reasoning"; case .plan: "plan"; case .tool: "tool"; case .result: "result"; case .error: "error"; case .child: "child"; case .files: "files"; case .artifact: "artifact"; case .usage: "usage"; case .unknown(let value): value }
    }
    public init(rawValue: String) {
        switch rawValue { case "message": self = .message; case "reasoning": self = .reasoning; case "plan": self = .plan; case "tool": self = .tool; case "result": self = .result; case "error": self = .error; case "child": self = .child; case "files": self = .files; case "artifact": self = .artifact; case "usage": self = .usage; default: self = .unknown(rawValue) }
    }
    public init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// The state of a tool invocation or result.
public enum ConversationToolStatus: String, Codable, Hashable, Sendable { case queued, running, success, failed, cancelled, unknown }

/// A normalized tool invocation with provider raw details preserved.
public struct ConversationTool: Codable, Hashable, Sendable {
    /// Stable provider tool identity.
    public var toolID: String
    /// Display name.
    public var name: String
    /// Input shown to the user.
    public var input: ConversationJSONValue?
    /// Output shown to the user.
    public var output: ConversationJSONValue?
    /// Current tool lifecycle state.
    public var status: ConversationToolStatus
    /// Whether the tool belongs to a child process.
    public var parentToolID: String?

    /// Creates tool details.
    public init(toolID: String, name: String, input: ConversationJSONValue? = nil, output: ConversationJSONValue? = nil, status: ConversationToolStatus, parentToolID: String? = nil) {
        self.toolID = toolID; self.name = name; self.input = input; self.output = output; self.status = status; self.parentToolID = parentToolID
    }
}

/// A structured file comparison retained in the conversation journal.
public struct ConversationDiff: Codable, Hashable, Sendable {
    /// Relative file path.
    public var path: String
    /// Unified diff text.
    public var text: String
    /// Source comparison, such as `unstaged` or `last-turn`.
    public var comparison: String
    /// Creates a file comparison.
    public init(path: String, text: String, comparison: String = "unstaged") { self.path = path; self.text = text; self.comparison = comparison }
}

/// A resumable binary artifact reference.
public struct ConversationArtifact: Codable, Hashable, Sendable {
    /// Stable artifact identity.
    public var artifactID: String
    /// Human-readable file name.
    public var fileName: String
    /// MIME type.
    public var mediaType: String
    /// Byte length when known.
    public var byteCount: Int64?
    /// Content hash used to resume and verify transfer.
    public var sha256: String?
    /// Transfer or download URL, if one exists.
    public var remoteURL: String?
    /// Creates an artifact reference.
    public init(artifactID: String, fileName: String, mediaType: String, byteCount: Int64? = nil, sha256: String? = nil, remoteURL: String? = nil) { self.artifactID = artifactID; self.fileName = fileName; self.mediaType = mediaType; self.byteCount = byteCount; self.sha256 = sha256; self.remoteURL = remoteURL }
}

/// Token and model usage metadata.
public struct ConversationUsage: Codable, Hashable, Sendable {
    /// Input token count.
    public var inputTokens: Int64?
    /// Output token count.
    public var outputTokens: Int64?
    /// Cached token count.
    public var cachedTokens: Int64?
    /// Model identifier.
    public var model: String?
    /// Creates usage metadata.
    public init(inputTokens: Int64? = nil, outputTokens: Int64? = nil, cachedTokens: Int64? = nil, model: String? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedTokens = cachedTokens; self.model = model }
}

/// A plan or progress item.
public struct ConversationPlan: Codable, Hashable, Sendable {
    /// Provider plan text.
    public var text: String
    /// Current progress label.
    public var status: String?
    /// Creates plan details.
    public init(text: String, status: String? = nil) { self.text = text; self.status = status }
}

/// One ordered item in the durable conversation projection.
public struct ConversationItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable item identity.
    public let id: ConversationItemID
    /// Journal sequence at which this item was last updated.
    public let sequence: ConversationCursor
    /// Owning turn, when known.
    public let turnID: ConversationTurnID?
    /// Normalized item kind.
    public let kind: ConversationItemKind
    /// Semantic message role when known (`user`, `assistant`, or `system`).
    public var role: String?
    /// User or assistant text.
    public var text: String?
    /// Structured tool information.
    public var tool: ConversationTool?
    /// Structured plan information.
    public var plan: ConversationPlan?
    /// Structured diff information.
    public var diff: ConversationDiff?
    /// Structured artifact information.
    public var artifact: ConversationArtifact?
    /// Usage metadata.
    public var usage: ConversationUsage?
    /// Original provider payload.
    public var rawPayload: ConversationJSONValue?

    /// Creates an ordered conversation item.
    public init(id: ConversationItemID, sequence: ConversationCursor, turnID: ConversationTurnID? = nil, kind: ConversationItemKind, role: String? = nil, text: String? = nil, tool: ConversationTool? = nil, plan: ConversationPlan? = nil, diff: ConversationDiff? = nil, artifact: ConversationArtifact? = nil, usage: ConversationUsage? = nil, rawPayload: ConversationJSONValue? = nil) {
        self.id = id; self.sequence = sequence; self.turnID = turnID; self.kind = kind; self.role = role; self.text = text; self.tool = tool; self.plan = plan; self.diff = diff; self.artifact = artifact; self.usage = usage; self.rawPayload = rawPayload
    }
}

public extension ConversationItem {
    /// Reduces the same compact event on the host, in durable replay, and on iOS.
    /// Full completion events replace partial content instead of appending twice.
    func applying(to previous: ConversationItem?, mode: ConversationItemUpdateMode?) -> ConversationItem {
        guard let mode, let previous, previous.id == id else { return self }
        var result = self
        result.role = role ?? previous.role
        switch mode {
        case .appendText:
            result.text = (previous.text ?? "") + (text ?? "")
            if var plan {
                plan.text = (previous.plan?.text ?? "") + plan.text
                result.plan = plan
            }
        case .appendToolOutput:
            if var tool {
                let prefix: String
                if case .string(let value)? = previous.tool?.output { prefix = value } else { prefix = "" }
                if case .string(let delta)? = tool.output { tool.output = .string(prefix + delta) }
                tool.input = tool.input ?? previous.tool?.input
                tool.parentToolID = tool.parentToolID ?? previous.tool?.parentToolID
                result.tool = tool
            }
        }
        return result
    }
}
