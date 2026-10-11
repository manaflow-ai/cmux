import Foundation

/// `harness.health {id}` (cx-ny85): the chat's agent CLI health (version, newest, sign-in, login
/// and update commands) from this Mac's acpmux, for the pane's notice above the composer.
@MainActor
public enum AgentPaneHarnessHealth {
    /// Set once by the app: this Mac's acpmux health row for a harness id (`refresh`: checked
    /// again), or nil.
    public static var provider: (@MainActor (_ id: String, _ refresh: Bool) async -> [String: Any]?)?

    /// The page's reply. A chat on another machine (`remote`) runs that machine's CLI, not this Mac's.
    static func respond(_ id: String, refresh: Bool, remote: Bool) async -> [String: Any] {
        guard !remote, let provider else { return AgentPaneReply.success() }
        return AgentPaneReply.success(["health": await provider(id, refresh) ?? NSNull()])
    }
}
