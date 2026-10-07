import Foundation

extension SidebarModel {
    /// `itemInfo` with the profile control applied: every account item
    /// carries `profileAvatar` and is named for the profile (its tooltip
    /// and VoiceOver label). What the bands draw.
    public var resolvedItemInfo: [LayoutItemID: SidebarItemInfo] {
        guard let avatar = profileAvatar else { return itemInfo }
        var infos = itemInfo
        for section in layout.sections {
            for item in section.items where item.ref == .builtIn(.account) {
                var info = infos[item.id] ?? SidebarBuiltIn.account.defaultInfo
                info.avatar = avatar
                info.title = avatar.name
                infos[item.id] = info
            }
        }
        return infos
    }
}
