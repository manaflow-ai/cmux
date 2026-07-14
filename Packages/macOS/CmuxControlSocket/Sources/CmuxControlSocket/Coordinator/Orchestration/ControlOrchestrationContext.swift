/// Summary row for one installed orchestration template.
public struct ControlOrchestrationSummary: Sendable {
    /// The template name (install directory name).
    public let name: String
    /// The template version string.
    public let version: String
    /// The template description.
    public let description: String
    /// The substrate kind (`worktree`, `clone-pool`, `script`).
    public let substrate: String
    /// The declared agent ids.
    public let agentIDs: [String]
    /// Where the install came from (git URL or local path).
    public let sourceDisplay: String
    /// Whether the user has confirmed the template's trust summary.
    public let trustConfirmed: Bool
    /// Parameter keys still lacking a resolved value.
    public let unansweredParameterKeys: [String]

    /// Creates an installed-orchestration summary row.
    public init(
        name: String,
        version: String,
        description: String,
        substrate: String,
        agentIDs: [String],
        sourceDisplay: String,
        trustConfirmed: Bool,
        unansweredParameterKeys: [String]
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.substrate = substrate
        self.agentIDs = agentIDs
        self.sourceDisplay = sourceDisplay
        self.trustConfirmed = trustConfirmed
        self.unansweredParameterKeys = unansweredParameterKeys
    }
}

/// One task passed to `orchestration.plan` / `orchestration.run`.
public struct ControlOrchestrationTaskInput: Sendable {
    /// The task title (required).
    public let title: String
    /// Optional longer task body.
    public let body: String?
    /// Optional issue number the task tracks.
    public let issueNumber: Int?

    /// Creates a task input.
    public init(title: String, body: String?, issueNumber: Int?) {
        self.title = title
        self.body = body
        self.issueNumber = issueNumber
    }
}

/// The parsed inputs shared by `orchestration.plan` and `orchestration.run`.
public struct ControlOrchestrationRunInputs: Sendable {
    /// The installed template name.
    public let name: String
    /// The tasks to plan workspaces for.
    public let tasks: [ControlOrchestrationTaskInput]
    /// Raw `--param key=value` overrides (coerced app-side by parameter type).
    public let parameterOverrides: [String: String]
    /// Optional agent-id override.
    public let agentID: String?

    /// Creates run inputs.
    public init(
        name: String,
        tasks: [ControlOrchestrationTaskInput],
        parameterOverrides: [String: String],
        agentID: String?
    ) {
        self.name = name
        self.tasks = tasks
        self.parameterOverrides = parameterOverrides
        self.agentID = agentID
    }
}

/// The result of `orchestration.list`.
public enum ControlOrchestrationListResolution: Sendable {
    /// Installed templates were read.
    case resolved([ControlOrchestrationSummary])
    /// The store could not be read.
    case failed(String)
}

/// The result of `orchestration.info`.
public enum ControlOrchestrationInfoResolution: Sendable {
    /// No template with the requested name is installed.
    case notInstalled
    /// The summary row plus a detail JSON object (parameters, steps, files).
    case resolved(summary: ControlOrchestrationSummary, detail: JSONValue)
    /// The store could not be read.
    case failed(String)
}

/// The result of `orchestration.plan`.
public enum ControlOrchestrationPlanResolution: Sendable {
    /// No template with the requested name is installed.
    case notInstalled
    /// Planning failed (unanswered parameters, bad agent, version gate, …).
    case planFailed(String)
    /// The run plan as a JSON object, plus current trust state.
    case resolved(plan: JSONValue, trustConfirmed: Bool)
    /// The store could not be read.
    case failed(String)
}

/// The result of `orchestration.run`.
public enum ControlOrchestrationRunResolution: Sendable {
    /// No template with the requested name is installed.
    case notInstalled
    /// Planning failed (unanswered parameters, bad agent, version gate, …).
    case planFailed(String)
    /// The template's trust summary has not been confirmed; `trust` carries
    /// the summary payload the client should show before retrying with
    /// `confirm_trust`.
    case needsTrustConfirmation(trust: JSONValue)
    /// The run was accepted and actuation started; the payload carries the
    /// run id, group name, and planned workspaces.
    case started(JSONValue)
    /// The run could not start.
    case failed(String)
}

/// The orchestration-domain slice of the control-command seam.
///
/// Trust model, enforced at this seam: `run` refuses to execute until the
/// user has confirmed the template's trust summary (scripts, agent commands,
/// substrate) either previously or via `confirmTrust` on this call.
@MainActor
public protocol ControlOrchestrationContext: AnyObject {
    /// Lists installed orchestration templates.
    func controlOrchestrationList() -> ControlOrchestrationListResolution

    /// Reads one installed template's summary and detail payload.
    func controlOrchestrationInfo(name: String) -> ControlOrchestrationInfoResolution

    /// Plans a run without executing anything.
    func controlOrchestrationPlan(
        inputs: ControlOrchestrationRunInputs
    ) -> ControlOrchestrationPlanResolution

    /// Plans a run and starts actuation (provision + workspaces) if trust is
    /// confirmed. Workspace creation never steals focus.
    func controlOrchestrationRun(
        routing: ControlRoutingSelectors,
        inputs: ControlOrchestrationRunInputs,
        confirmTrust: Bool
    ) -> ControlOrchestrationRunResolution
}
