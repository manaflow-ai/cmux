import Foundation

/// A provider-neutral option exposed by an agent session.
public struct ChatSessionControlOption: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String?

    public init(id: String, displayName: String, description: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case description
    }
}

/// Mutable execution controls for one live coding-agent session.
///
/// Values are opaque provider identifiers. The host owns translation to the
/// provider's command protocol, which keeps iOS independent of Claude,
/// Codex, and OpenCode spelling differences.
public struct ChatSessionControls: Codable, Equatable, Sendable {
    public var modelID: String?
    public var reasoningEffortID: String?
    public var permissionMode: String?
    public var sandboxMode: String?
    public var planMode: Bool
    public var modelOptions: [ChatSessionControlOption]
    public var reasoningEffortOptions: [ChatSessionControlOption]
    public var permissionOptions: [ChatSessionControlOption]
    public var sandboxOptions: [ChatSessionControlOption]
    public var supportsPlanMode: Bool

    public init(
        modelID: String? = nil,
        reasoningEffortID: String? = nil,
        permissionMode: String? = nil,
        sandboxMode: String? = nil,
        planMode: Bool = false,
        modelOptions: [ChatSessionControlOption] = [],
        reasoningEffortOptions: [ChatSessionControlOption] = [],
        permissionOptions: [ChatSessionControlOption] = [],
        sandboxOptions: [ChatSessionControlOption] = [],
        supportsPlanMode: Bool = false
    ) {
        self.modelID = modelID
        self.reasoningEffortID = reasoningEffortID
        self.permissionMode = permissionMode
        self.sandboxMode = sandboxMode
        self.planMode = planMode
        self.modelOptions = modelOptions
        self.reasoningEffortOptions = reasoningEffortOptions
        self.permissionOptions = permissionOptions
        self.sandboxOptions = sandboxOptions
        self.supportsPlanMode = supportsPlanMode
    }

    private enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case reasoningEffortID = "reasoning_effort_id"
        case permissionMode = "permission_mode"
        case sandboxMode = "sandbox_mode"
        case planMode = "plan_mode"
        case modelOptions = "model_options"
        case reasoningEffortOptions = "reasoning_effort_options"
        case permissionOptions = "permission_options"
        case sandboxOptions = "sandbox_options"
        case supportsPlanMode = "supports_plan_mode"
    }
}

public struct ChatSessionControlsResponse: Codable, Equatable, Sendable {
    public let controls: ChatSessionControls

    public init(controls: ChatSessionControls) {
        self.controls = controls
    }
}
