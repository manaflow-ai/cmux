import Combine
import Foundation

/// The window's committed workspace selection, which every sidebar row's
/// highlight is derived from.
///
/// `selectedWorkspaceIds` must publish synchronously as the selection commits
/// (TabManager's `selectedTabIdPublisher` sends from `willSet`), so the table
/// can repaint in the turn of the click or shortcut rather than after SwiftUI
/// rebuilds the rows behind the workspace content switch.
@MainActor
struct SidebarWorkspaceSelectionSource {
    /// The selection's owner; binding the same owner again keeps the
    /// existing subscription.
    let owner: ObjectIdentifier
    let selectedWorkspaceIds: AnyPublisher<UUID?, Never>
    /// The sidebar multi-selection as it is right now.
    let multiSelectedWorkspaceIds: () -> Set<UUID>
}
