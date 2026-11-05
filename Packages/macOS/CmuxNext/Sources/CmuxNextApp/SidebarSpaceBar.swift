import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// The sidebar's space bar: the local daemon's profiles with their stored icons (`SidebarMapping.spaces`).
/// Window `window` never lists another window's incognito space (spaces-incognito-audit leak 9): a normal
/// window lists none, and so its sidebar snapshot records none.
@MainActor enum SidebarSpaceBar {
    static func profiles(_ local: DaemonService, window: String, windows: WindowManager) -> [SidebarProfile] {
        SidebarMapping.spaces(local.store, image: IconAssetImages.shared.sidebarIcon(owner: local),
                              hiding: windows.incognitoSpaceMarks.hidden(except: windows.incognitoSpaces[window]))
    }
}
