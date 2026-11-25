public import CmuxNextDaemon
public import CmuxNextSidebar
import CmuxNextDesign

extension SidebarMapping {
    /// The sidebar's space bar: `store`'s profiles in order (empty when it has none; the bar hides
    /// below two), each with its stored image or SVG icon once `image` has read it (cx-qno.2.2). Spaces in
    /// `hiding` (incognito spaces in a normal window) are left out.
    public static func spaces(_ store: DaemonStore, image: (String) -> SidebarFavicon?, hiding: Set<String> = []) -> [SidebarProfile] {
        store.profiles.filter { !hiding.contains($0.id.rawValue) }.sorted { $0.index < $1.index }.map { profile in
            SidebarProfile(id: SidebarProfileKey(profile.id.rawValue), name: profile.name,
                           color: profile.color.flatMap(GroupColor.init(rawValue:)), icon: profile.icon,
                           image: profile.icon.flatMap(image))
        }
    }
}
