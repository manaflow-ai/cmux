/// Who asks for a grant: the agent and the workspace it works in, as the
/// card names them.
///
/// The App fills it from the control call: the workspace from the caller's
/// terminal (the app's own topology), the agent name as the caller claims it.
/// `isClaimed` is true while the agent name is the caller's word, so the
/// card can say so (plans/cmux-next/agent-permissions-DESIGN.md section 8).
public nonisolated struct PermissionRequester: Sendable, Equatable {
    /// The agent's display name ("Claude Code", "Codex", "a214").
    public var agentName: String
    /// A stable id for the agent (terminal id or agent session), used to join
    /// duplicate requests; nil when unknown.
    public var agentID: String?
    /// The workspace's name, when the caller runs inside one.
    public var workspaceName: String?
    /// The workspace's public id (`ws_…`), when known.
    public var workspaceID: String?
    /// The agent name is the caller's claim, not verified by cmux.
    public var isClaimed: Bool

    public init(agentName: String, agentID: String? = nil, workspaceName: String? = nil, workspaceID: String? = nil,
                isClaimed: Bool = true) {
        self.agentName = agentName
        self.agentID = agentID
        self.workspaceName = workspaceName
        self.workspaceID = workspaceID
        self.isClaimed = isClaimed
    }
}
