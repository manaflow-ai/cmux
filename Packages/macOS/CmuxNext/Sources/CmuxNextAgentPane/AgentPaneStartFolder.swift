public import Foundation

/// Where a new chat of this pane starts: the store's answer (`workspace.agent_start.get`,
/// cx-9aps), which the pane only shows and sends. One value for the handshake's folder, the
/// page's folder chip and private-folder line, and the relay's fill of a `session/new` without
/// a folder.
public nonisolated struct AgentPaneStartFolder: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case seed, chosen, workspace
        case agentHome = "agent_home"
    }

    /// Why a proposed folder was not used.
    public enum Skip: String, Sendable {
        case home
        case aboveHome = "above_home"
        case agentHome = "agent_home"
        case missing
    }

    public var kind: Kind
    /// The folder, canonical; nil only for ``Kind/agentHome`` when the workspace names no folder.
    public var cwd: String?
    /// The workspace's agent-home folder.
    public var agentHome: String?
    /// The proposed folder when it was not used, and why.
    public var skipped: (cwd: String, reason: Skip)?

    public init(kind: Kind, cwd: String?, agentHome: String?, skipped: (cwd: String, reason: Skip)? = nil) {
        self.kind = kind
        self.cwd = cwd
        self.agentHome = agentHome
        self.skipped = skipped
    }

    /// The store's answer in its wire spelling; nil for a kind or reason this build does not know.
    public init?(kind: String, cwd: String?, agentHome: String?, skipped: (cwd: String, reason: String)?) {
        guard let kind = Kind(rawValue: kind) else { return nil }
        var skip: (cwd: String, reason: Skip)?
        if let skipped {
            guard let reason = Skip(rawValue: skipped.reason) else { return nil }
            skip = (skipped.cwd, reason)
        }
        self.init(kind: kind, cwd: cwd, agentHome: agentHome, skipped: skip)
    }

    /// The folder a chat starts in when it is a real folder (not the private agent-home one).
    public var folder: String? { kind == .agentHome ? nil : cwd }

    /// The agent-home folder as the relay's fill: its base and the workspace's id.
    var agentHomeFill: AgentHomeFill? {
        guard let agentHome else { return nil }
        let url = URL(fileURLWithPath: agentHome)
        return AgentHomeFill(home: AgentHome(base: url.deletingLastPathComponent().path), workspace: url.lastPathComponent)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.cwd == rhs.cwd && lhs.agentHome == rhs.agentHome
            && lhs.skipped?.cwd == rhs.skipped?.cwd && lhs.skipped?.reason == rhs.skipped?.reason
    }
}
