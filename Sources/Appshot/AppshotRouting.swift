import Foundation

/// Recency state used to decide where an appshot is delivered.
struct AppshotRoutingState: Equatable {
    /// Default recency window, in seconds, matching the Codex Appshots behavior.
    static let defaultRecencyWindow: TimeInterval = 60

    /// The surface the previous appshot was delivered to. Lets consecutive
    /// appshots stack onto the same thread.
    var lastRoute: AppshotAgentRef?
    /// The agent surface the user most recently interacted with (snapshotted
    /// when cmux resigns active, or resolved live while cmux is frontmost).
    var lastInteractiveAgent: AppshotAgentRef?

    init(lastRoute: AppshotAgentRef? = nil, lastInteractiveAgent: AppshotAgentRef? = nil) {
        self.lastRoute = lastRoute
        self.lastInteractiveAgent = lastInteractiveAgent
    }

    /// Resolves where an appshot should be delivered, implementing the issue's
    /// 60-second recency rule:
    ///
    /// - If the previous appshot was delivered within the window and its surface
    ///   still exists, stack onto it (consecutive appshots stay together).
    /// - Otherwise, if the user interacted with an agent within the window and
    ///   that surface still exists, append to it.
    /// - Otherwise report `.noRecentTarget`; this decision does not itself pick a
    ///   destination. The caller owns the fallback — `AppshotController` routes
    ///   to the active agent (the front window's focused terminal) and opens a
    ///   fresh workspace only when no terminal surface exists.
    ///
    /// `lastRouteSurfaceExists` / `lastInteractiveSurfaceExists` are computed by
    /// the caller on the main actor (terminal-panel existence is main-actor
    /// state). Passing them in as plain booleans keeps this decision pure,
    /// isolation-free, and unit-testable.
    func resolvedRoute(
        now: Date,
        window: TimeInterval = defaultRecencyWindow,
        lastRouteSurfaceExists: Bool,
        lastInteractiveSurfaceExists: Bool
    ) -> AppshotRoute {
        if let last = lastRoute,
           now.timeIntervalSince(last.at) <= window,
           lastRouteSurfaceExists {
            return .append(workspaceId: last.workspaceId, panelId: last.panelId)
        }
        if let agent = lastInteractiveAgent,
           now.timeIntervalSince(agent.at) <= window,
           lastInteractiveSurfaceExists {
            return .append(workspaceId: agent.workspaceId, panelId: agent.panelId)
        }
        return .noRecentTarget
    }
}
