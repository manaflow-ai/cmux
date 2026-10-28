import AppKit
import SwiftUI

/// Group Color submenu for the SwiftUI group header, laid out like the
/// workspace row's Workspace Color submenu. Only the group's own color is
/// checked and clearable; a `workspaceGroups.byCwd` config color is not.
struct SidebarWorkspaceGroupColorMenu: View {
    let tintHex: String?
    let hasCustomColor: Bool
    let actions: SidebarGroupHeaderRowActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu(String(localized: "workspaceGroup.contextMenu.color", defaultValue: "Group Color")) {
            let palette = WorkspaceTabColorSettings.palette()
            let currentColorHex = hasCustomColor ? tintHex : nil
            if hasCustomColor {
                Button {
                    actions.onSetColor(nil)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }
            Button(action: actions.onChooseCustomColor) {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }
            if !palette.isEmpty {
                Divider()
            }
            ForEach(palette, id: \.id) { entry in
                let isSelected = WorkspaceTabColorSettings.paletteEntryMatches(
                    currentHex: currentColorHex,
                    entryHex: entry.hex
                )
                Button {
                    actions.onSetColor(entry.hex)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .opacity(isSelected ? 1 : 0)
                            .frame(width: 12)
                        Image(nsImage: coloredCircleImage(color: swatch(for: entry.hex)))
                        Text(entry.name)
                    }
                }
            }
        }
    }

    private func swatch(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: true)
            ?? NSColor(hex: hex) ?? .gray
    }
}
