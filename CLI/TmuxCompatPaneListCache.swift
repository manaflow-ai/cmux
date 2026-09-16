import Foundation

/// Caches pane topology reads during one CLI socket connection.
///
/// Tmux compatibility target resolution asks for the same workspace pane list
/// several times before and after formatting a command result. Reusing a read
/// within the connection avoids charging duplicate observations to the socket
/// polling bucket. Any RPC that could change pane topology clears the cache
/// before it runs, so a later read cannot observe stale layout state.
final class TmuxCompatPaneListCache {
    private var payloads: [String: [String: Any]] = [:]

    func payload(for workspaceID: String) -> [String: Any]? {
        payloads[workspaceID]
    }

    func store(_ payload: [String: Any], for workspaceID: String) {
        payloads[workspaceID] = payload
    }

    func invalidateIfNeeded(for method: String) {
        if !Self.topologyPreservingMethods.contains(method) {
            payloads.removeAll(keepingCapacity: true)
        }
    }

    private static let topologyPreservingMethods: Set<String> = [
        "pane.list",
        "pane.surfaces",
        "surface.list",
        "surface.current",
        "surface.read_text",
        "surface.read_selection",
        "workspace.list",
        "workspace.current",
        "window.list",
        "window.current",
        "window.displays",
        "system.top",
        "system.memory",
        "system.tree",
        "system.identify",
    ]
}

extension SocketClient {
    /// Returns a workspace's pane list, reusing it until a topology-changing
    /// RPC is sent through this connection.
    func tmuxCompatPaneListSnapshot(workspaceID: String) throws -> [String: Any] {
        if let payload = tmuxCompatPaneListCache.payload(for: workspaceID) {
            return payload
        }
        let payload = try sendV2(
            method: "pane.list",
            params: ["workspace_id": workspaceID]
        )
        tmuxCompatPaneListCache.store(payload, for: workspaceID)
        return payload
    }
}
