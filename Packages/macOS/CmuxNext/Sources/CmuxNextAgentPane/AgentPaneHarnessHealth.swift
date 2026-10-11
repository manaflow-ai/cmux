import Foundation

/// `harness.health {id}` (cx-ny85): the chat's agent CLI health (version, newest, sign-in, login
/// and update commands) from this Mac's acpmux, for the pane's notice above the composer.
extension AgentPaneModel {
    /// Set once by the app: this Mac's acpmux health row for a harness id (`refresh`: checked
    /// again), or nil.
    @MainActor public static var harnessHealthProvider: (@MainActor (_ id: String, _ refresh: Bool) async -> [String: Any]?)?

    /// The page's reply. A chat on another machine (`remoteChat`) runs that machine's CLI, not this Mac's.
    func harnessHealthReply(_ id: String, refresh: Bool) async -> [String: Any] {
        guard !remoteChat, let provider = Self.harnessHealthProvider else { return AgentPaneReply.success() }
        guard let row = await provider(id, refresh) else { return AgentPaneReply.success(["health": NSNull()]) }
        return AgentPaneReply.success(["health": row])
    }
}
