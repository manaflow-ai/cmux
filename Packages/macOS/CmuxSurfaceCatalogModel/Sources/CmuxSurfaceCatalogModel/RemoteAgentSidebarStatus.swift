import Foundation

/// The sidebar status a remote terminal's agent row maps to, so an agent on
/// an SSH host reads like a local one (Running, Needs input, Idle).
///
/// The daemon reports `working`, `blocked`, `idle`, `done`, or `unknown`.
/// `done` and `unknown` show nothing. Slots use their own key namespace, so a
/// remote row never takes over the local hook's `claude_code`/`codex` slot,
/// which is gated on a local agent PID.
public struct RemoteAgentSidebarStatus: Hashable, Sendable {
    public enum Activity: Int, Hashable, Sendable, Comparable {
        case idle
        case running
        case needsInput

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static let statusKeyPrefix = "cmux.remote.agent:"

    /// Workspace status and lifecycle slot, one per agent kind.
    public let statusKey: String
    public let activity: Activity

    public init(statusKey: String, activity: Activity) {
        self.statusKey = statusKey
        self.activity = activity
    }

    public init?(badge: SurfaceAgentBadge) {
        let activity: Activity
        switch badge.state.lowercased() {
        case "working": activity = .running
        case "blocked": activity = .needsInput
        case "idle": activity = .idle
        default: return nil
        }
        self.init(statusKey: Self.statusKeyPrefix + Self.agentKey(for: badge), activity: activity)
    }

    public static func isOwnedStatusKey(_ key: String) -> Bool {
        key.hasPrefix(statusKeyPrefix)
    }

    /// The adapter identity (`claude`, `codex`, ...), never report provenance.
    static func agentKey(for badge: SurfaceAgentBadge) -> String {
        let provenance: Set<String> = ["hook", "socket", "detected", "plugin", "unknown"]
        let identity = [badge.agent, badge.source]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty && !provenance.contains($0) }
        switch identity {
        case "claude", "claude-code", "claude_code": return "claude_code"
        case let identity?:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            let bounded = String(identity.unicodeScalars.filter(allowed.contains).prefix(64))
            return bounded.isEmpty ? "agent" : bounded
        case nil: return "agent"
        }
    }

    /// One slot per agent kind in a workspace: the most urgent activity wins,
    /// so any blocked terminal shows Needs input.
    public static func workspaceSlots(_ statuses: some Sequence<RemoteAgentSidebarStatus>) -> [String: Activity] {
        var slots: [String: Activity] = [:]
        for status in statuses {
            slots[status.statusKey] = max(slots[status.statusKey] ?? status.activity, status.activity)
        }
        return slots
    }
}
