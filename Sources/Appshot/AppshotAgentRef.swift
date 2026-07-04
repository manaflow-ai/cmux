import Foundation

/// Identifies an agent surface (terminal panel) the appshot can be routed to,
/// stamped with the time of the interaction it represents.
struct AppshotAgentRef: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let at: Date
}
