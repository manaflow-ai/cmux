import Combine
import Foundation
import Observation

/// Narrows the app-wide unread model to this Dock before updating its Bonsplit
/// subtree. Hidden Docks clear once, then ignore unrelated notification churn.
@MainActor
@Observable
final class DockUnreadPanelProjection {
    private(set) var unreadPanelIDs: Set<UUID> = []

    @ObservationIgnored private let workspaceID: UUID
    @ObservationIgnored private var panelIDs: Set<UUID> = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>
    @ObservationIgnored private var focusedReadIndicatorByWorkspaceID: [UUID: UUID]
    @ObservationIgnored private var unreadSubscription: AnyCancellable?

    init(
        source: SidebarUnreadModel,
        workspaceID: UUID,
        panelIDs: Set<UUID>,
        isActive: Bool
    ) {
        self.workspaceID = workspaceID
        self.panelIDs = panelIDs
        self.isActive = isActive
        unreadSurfaceKeys = source.unreadSurfaceKeys
        focusedReadIndicatorByWorkspaceID = source.focusedReadIndicatorByWorkspaceId
        refresh()
        unreadSubscription = source.$unreadSurfaceKeys.combineLatest(
            source.$focusedReadIndicatorByWorkspaceId
        ).sink { [weak self] unreadSurfaceKeys, focusedReadIndicatorByWorkspaceID in
            // Both publishers are main-actor-owned and publish synchronously
            // from SidebarUnreadModel.apply().
            MainActor.assumeIsolated {
                self?.receive(
                    unreadSurfaceKeys: unreadSurfaceKeys,
                    focusedReadIndicatorByWorkspaceID: focusedReadIndicatorByWorkspaceID
                )
            }
        }
    }

    func updateContext(panelIDs: Set<UUID>, isActive: Bool) {
        guard self.panelIDs != panelIDs || self.isActive != isActive else { return }
        self.panelIDs = panelIDs
        self.isActive = isActive
        refresh()
    }

    private func receive(
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceID: [UUID: UUID]
    ) {
        self.unreadSurfaceKeys = unreadSurfaceKeys
        self.focusedReadIndicatorByWorkspaceID = focusedReadIndicatorByWorkspaceID
        refresh()
    }

    private func refresh() {
        let nextUnreadPanelIDs: Set<UUID>
        if isActive {
            let focusedReadPanelID = focusedReadIndicatorByWorkspaceID[workspaceID]
            nextUnreadPanelIDs = Set(panelIDs.filter { panelID in
                unreadSurfaceKeys.contains(
                    SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: panelID)
                ) || focusedReadPanelID == panelID
            })
        } else {
            nextUnreadPanelIDs = []
        }
        guard unreadPanelIDs != nextUnreadPanelIDs else { return }
        unreadPanelIDs = nextUnreadPanelIDs
    }
}
