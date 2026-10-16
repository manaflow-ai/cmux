import AppKit
import SwiftUI

/// Builds the named palette rows shared by the native sidebar color submenu.
/// Arbitrary custom colors remain unmarked unless they match a palette entry.
@MainActor
struct SidebarWorkspaceRowColorMenu {
    let currentColorHex: String?
    let colorScheme: ColorScheme
    var brightenInDarkMode = true

    /// Adds one menu item per palette entry and marks the matching current value.
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
                forceBright: false,
                brightenInDarkMode: brightenInDarkMode
            ) ?? NSColor(hex: entry.hex) ?? .gray
            colorItem.image = SidebarWorkspaceRowMenuBuilder.coloredCircleImage(color: swatch)
            // macOS 27 hides menu item images unless the item opts in.
            // Guarded for CI toolchains that predate the macOS 27 SDK.
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                colorItem.preferredImageVisibility = .visible
            }
            #endif
            menu.addItem(colorItem)
        }
    }
}
