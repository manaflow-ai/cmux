import Foundation

/// Identifies an agent surface (terminal panel) the appshot can be routed to,
/// stamped with the time of the interaction it represents.
struct AppshotAgentRef: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let at: Date
}

/// Recency state used to decide where an appshot is delivered.
struct AppshotRoutingState: Equatable {
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
}

/// Where an appshot should be delivered.
enum AppshotRoute: Equatable {
    /// Append to (and submit into) an existing agent surface.
    case append(workspaceId: UUID, panelId: UUID)
    /// Start a fresh workspace/thread because no recent agent qualifies.
    case newThread
}

/// Pure resolver implementing the issue's 60-second recency rule.
///
/// - If the previous appshot was delivered within the window and its surface
///   still exists, stack onto it (consecutive appshots stay together).
/// - Otherwise, if the user interacted with an agent within the window and that
///   surface still exists, append to it.
/// - Otherwise start a new thread.
enum AppshotRouteResolver {
    /// Default recency window, in seconds, matching the Codex Appshots behavior.
    static let defaultRecencyWindow: TimeInterval = 60

    /// `lastRouteSurfaceExists` / `lastInteractiveSurfaceExists` are computed by
    /// the caller on the main actor (terminal-panel existence is main-actor
    /// state). Passing them in as plain booleans keeps this resolver pure,
    /// isolation-free, and unit-testable.
    static func resolve(
        now: Date,
        window: TimeInterval = defaultRecencyWindow,
        state: AppshotRoutingState,
        lastRouteSurfaceExists: Bool,
        lastInteractiveSurfaceExists: Bool
    ) -> AppshotRoute {
        if let last = state.lastRoute,
           now.timeIntervalSince(last.at) <= window,
           lastRouteSurfaceExists {
            return .append(workspaceId: last.workspaceId, panelId: last.panelId)
        }
        if let agent = state.lastInteractiveAgent,
           now.timeIntervalSince(agent.at) <= window,
           lastInteractiveSurfaceExists {
            return .append(workspaceId: agent.workspaceId, panelId: agent.panelId)
        }
        return .newThread
    }
}
