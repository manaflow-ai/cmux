import Foundation

/// The facts about one workspace that the automatic sidebar grouping reads.
///
/// A plain value so section computation stays pure: the app builds one per
/// workspace from live state (see `SidebarWorkspaceGroupingProjection`), and
/// tests build them directly.
struct SidebarAutoGroupingInput: Equatable, Sendable {
    let workspaceId: UUID
    let host: SidebarAutoGroupingHost
    let status: SidebarAutoGroupingStatus
}
