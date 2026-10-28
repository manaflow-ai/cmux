import AppKit
import SwiftUI

/// Group Color submenu for the AppKit group header, laid out like the workspace
/// row's Workspace Color submenu. Only the group's own color is checked and
/// clearable; a `workspaceGroups.byCwd` config color is not.
@MainActor
struct SidebarGroupHeaderColorMenu {
    let model: SidebarGroupHeaderRowModel
    let actions: SidebarGroupHeaderRowActions

    /// The "Group Color" parent item carrying the submenu.
    func makeItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let palette = WorkspaceTabColorSettings.palette()
        if model.hasCustomColor {
            let clearItem = SidebarRowMenuActionItem(
                title: String(localized: "contextMenu.clearColor", defaultValue: "Clear Color")
            ) { [actions] in actions.onSetColor(nil) }
            clearItem.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "xmark.circle", pointSize: 13, weight: nil
            )
            submenu.addItem(clearItem)
        }
        let customItem = SidebarRowMenuActionItem(
            title: String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"),
            run: actions.onChooseCustomColor
        )
        customItem.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "paintpalette", pointSize: 13, weight: nil
        )
        submenu.addItem(customItem)
        if !palette.isEmpty {
            submenu.addItem(.separator())
        }
        SidebarWorkspaceRowColorMenu(
            currentColorHex: model.hasCustomColor ? model.tintHex : nil,
            colorScheme: model.colorSchemeIsDark ? .dark : .light
        ).addPaletteItems(to: submenu, palette: palette) { [actions] hex in
            actions.onSetColor(hex)
        }
        let parent = NSMenuItem(
            title: String(localized: "workspaceGroup.contextMenu.color", defaultValue: "Group Color"),
            action: nil,
            keyEquivalent: ""
        )
        parent.submenu = submenu
        return parent
    }
}
