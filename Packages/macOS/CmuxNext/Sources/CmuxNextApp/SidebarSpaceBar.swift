import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// The sidebar's space bar: the local daemon's profiles with their stored icons (`SidebarMapping.spaces`).
@MainActor enum SidebarSpaceBar {
    static func profiles(_ local: DaemonService) -> [SidebarProfile] {
        SidebarMapping.spaces(local.store, image: IconAssetImages.shared.sidebarIcon(owner: local))
    }
}
