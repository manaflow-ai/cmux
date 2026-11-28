import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// The sidebar's space bar: the local daemon's profiles (empty when it has none; the bar
/// hides below two), each with its stored image or SVG icon once read (cx-qno.2.2).
@MainActor enum SidebarSpaceBar {
    static func profiles(_ local: DaemonService) -> [SidebarProfile] {
        profiles(local.store, image: IconAssetImages.shared.sidebarIcon(owner: local))
    }

    static func profiles(_ store: DaemonStore, image: (String) -> SidebarFavicon?) -> [SidebarProfile] {
        store.profiles.sorted { $0.index < $1.index }.map { profile in
            SidebarProfile(id: SidebarProfileKey(profile.id.rawValue), name: profile.name,
                           color: profile.color.flatMap(GroupColor.init(rawValue:)), icon: profile.icon,
                           image: profile.icon.flatMap(image))
        }
    }
}
