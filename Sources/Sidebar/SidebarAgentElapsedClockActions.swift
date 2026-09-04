import Foundation

/// Closure capability passed below the sidebar's lazy-list boundary.
///
/// The value is deliberately not observable: registering a realized label
/// cannot invalidate `VerticalTabsSidebar` or rebuild its row snapshots.
@MainActor
struct SidebarAgentElapsedClockActions {
    let identity: ObjectIdentifier
    let register: (any SidebarAgentElapsedClockTarget) -> Void
    let unregister: (any SidebarAgentElapsedClockTarget) -> Void
    let displayPayload: @MainActor (SidebarWorkspaceAgentActivity, Date) -> SidebarAgentActivityDisplayPayload
}
