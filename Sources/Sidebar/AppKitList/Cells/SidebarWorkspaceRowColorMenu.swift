import AppKit
import SwiftUI

/// Builds the named palette rows shared by the native sidebar color submenu.
/// Arbitrary custom colors remain unmarked unless they match a palette entry.
@MainActor
struct SidebarWorkspaceRowColorMenu {
    let currentColorHex: String?
    let colorScheme: ColorScheme

    func addPaletteItems(
        to menu: NSMenu,
        palette: [WorkspaceTabColorEntry],
        apply: @escaping (String) -> Void
    ) {
        for entry in palette {
            let colorItem = SidebarRowMenuActionItem(title: entry.name) {
                apply(entry.hex)
            }
            colorItem.state = WorkspaceTabColorSettings.paletteEntryMatches(
                currentHex: currentColorHex,
                entryHex: entry.hex
            ) ? .on : .off
            let swatch = WorkspaceTabColorSettings.displayNSColor(
                hex: entry.hex,
                colorScheme: colorScheme,
                forceBright: false
            ) ?? NSColor(hex: entry.hex) ?? .gray
            colorItem.image = SidebarWorkspaceRowMenuBuilder.coloredCircleImage(color: swatch)
            menu.addItem(colorItem)
        }
    }
}
