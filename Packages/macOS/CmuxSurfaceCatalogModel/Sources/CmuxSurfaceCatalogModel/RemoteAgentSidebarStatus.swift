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

    /// The sidebar slot name for the badge's adapter; Claude keeps its local `claude_code` key.
    static func agentKey(for badge: SurfaceAgentBadge) -> String {
        switch badge.agentIdentity {
        case "claude": return "claude_code"
        case let identity?: return identity
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
