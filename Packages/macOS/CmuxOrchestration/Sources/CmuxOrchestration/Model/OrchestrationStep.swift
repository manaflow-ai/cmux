import Foundation

/// An agent command template declared by the manifest.
///
/// The command is what gets typed into a task workspace's terminal. It is a
/// placeholder template; `{{prompt}}` expands to the shell-quoted rendered
/// prompt text and `{{prompt_file}}` to the path of the rendered prompt file
/// written into the workspace. Auth is never part of a template: the command
/// runs with whatever credentials the user's machine already has.
public struct OrchestrationAgent: Sendable, Hashable, Codable {
    /// Identifier referenced by steps and the `agent`-typed parameter.
    public var id: String
    /// Optional name in cmux's agent registry (e.g. "claude", "codex") that
    /// this command corresponds to. Purely informational in v1; lets future
    /// UI resolve registry metadata such as resume/fork commands.
    public var registryAgent: String?
    /// Command template, e.g. `claude --permission-mode acceptEdits "$(cat {{prompt_file}})"`.
    public var command: String

    public init(id: String, registryAgent: String? = nil, command: String) {
        self.id = id
        self.registryAgent = registryAgent
        self.command = command
    }
}

/// Success condition for a step.
public enum OrchestrationStepSuccess: Sendable, Hashable, Codable {
    /// The step's command exits with this code (default 0).
    case exitCode(Int)
    /// A pull request exists for the task branch.
    case prExists
    /// A named cmux agent-hook event fires (e.g. `Stop`).
    case hookEvent(name: String)

    enum CodingKeys: String, CodingKey {
        case kind
        case code
        case event
    }

    enum Kind: String, Codable {
        case exitCode = "exit-code"
        case prExists = "pr-exists"
        case hookEvent = "hook-event"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown success kind '\(kindString)'; expected exit-code, pr-exists, or hook-event"
            )
        }
        switch kind {
        case .exitCode:
            self = .exitCode(try container.decodeIfPresent(Int.self, forKey: .code) ?? 0)
        case .prExists:
            self = .prExists
        case .hookEvent:
            self = .hookEvent(name: try container.decode(String.self, forKey: .event))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exitCode(let code):
            try container.encode(Kind.exitCode.rawValue, forKey: .kind)
            try container.encode(code, forKey: .code)
        case .prExists:
            try container.encode(Kind.prExists.rawValue, forKey: .kind)
        case .hookEvent(let name):
            try container.encode(Kind.hookEvent.rawValue, forKey: .kind)
            try container.encode(name, forKey: .event)
        }
    }
}

/// What to do when a step's success condition is not met.
public enum OrchestrationStepFailurePolicy: Sendable, Hashable, Codable {
    /// Re-run the step up to `attempts` additional times.
    case retry(attempts: Int)
    /// Park the task and ask the user to intervene.
    case needsInput

    enum CodingKeys: String, CodingKey {
        case kind
        case attempts
    }

    enum Kind: String, Codable {
        case retry
        case needsInput = "needs-input"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown on-failure kind '\(kindString)'; expected retry or needs-input"
            )
        }
        switch kind {
        case .retry:
            self = .retry(attempts: try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 1)
        case .needsInput:
            self = .needsInput
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .retry(let attempts):
            try container.encode(Kind.retry.rawValue, forKey: .kind)
            try container.encode(attempts, forKey: .attempts)
        case .needsInput:
            try container.encode(Kind.needsInput.rawValue, forKey: .kind)
        }
    }
}

/// One entry of the optional linear step chain (plan -> code -> review).
///
/// v1 is deliberately linear: no DAGs, no fan-out inside a task. The fleet
/// engine consumes these as an ordered list.
public struct OrchestrationStep: Sendable, Hashable, Codable {
    public var id: String
    /// Agent id declared in the manifest's `agents` array.
    public var agent: String
    /// Template-relative path to the step's prompt template.
    public var prompt: String
    public var success: OrchestrationStepSuccess?
    public var onFailure: OrchestrationStepFailurePolicy?

    public init(
        id: String,
        agent: String,
        prompt: String,
        success: OrchestrationStepSuccess? = nil,
        onFailure: OrchestrationStepFailurePolicy? = nil
    ) {
        self.id = id
        self.agent = agent
        self.prompt = prompt
        self.success = success
        self.onFailure = onFailure
    }
}
