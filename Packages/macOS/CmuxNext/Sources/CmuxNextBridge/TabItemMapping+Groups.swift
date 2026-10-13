public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextTabs

extension TabItemMapping {
    /// A pane strip's chip for tab group `group`: its name, color, collapse
    /// state, whether a saved record links it, and its icon
    /// (`tab-group-icon-v1`, ``groupIcon(_:asset:)``). `asset` draws a stored
    /// image or SVG icon (the App reads it from the group's daemon).
    public func groupItem(_ group: TabGroupModel, isSaved: Bool, asset: (String) -> TabImage? = { _ in nil }) -> TabGroupItem {
        TabGroupItem(id: CmuxNextTabs.TabGroupID(group.id.rawValue), name: group.name,
                     tint: group.color.flatMap(GroupTint.init(wire:)) ?? .palette(.grey),
                     isCollapsed: group.collapsed, isSaved: isSaved, icon: groupIcon(group.icon, asset: asset))
    }

    /// A group chip's icon: an emoji drawn to a full-color image, an SF
    /// Symbol this Mac draws, a stored asset's image (``TabUserIcon``, the
    /// rule tab icons use). A stored asset not read yet draws the placeholder
    /// symbol, as a screen's does, so the chip keeps its width when the image
    /// arrives. Nil for no icon or one this Mac cannot draw.
    public func groupIcon(_ wire: String?, asset: (String) -> TabImage? = { _ in nil }) -> TabIcon? {
        if let icon = TabUserIcon.shared.icon(wire, asset: asset) { return icon }
        switch IconValue(wire: wire) {
        case .image?, .svg?: return .symbol("photo")
        case .emoji?, .symbol?, nil: return nil
        }
    }
}
