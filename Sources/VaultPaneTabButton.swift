import CmuxFoundation
import SwiftUI

/// One selectable item in the Vault Sessions/History tab bar.
struct VaultPaneTabButton: View {
    let tab: VaultPaneTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                CmuxSystemSymbolImage(
                    magnified: tab.symbolName,
                    pointSize: RightSidebarChromeControlStyle.secondaryIconSize,
                    weight: RightSidebarChromeControlStyle.iconWeight
                )
                Text(tab.label)
                    .cmuxFont(
                        size: RightSidebarChromeControlStyle.labelSize,
                        weight: RightSidebarChromeControlStyle.labelWeight
                    )
                    .lineLimit(1)
            }
            .rightSidebarChromePill(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .titlebarInteractiveControl()
        .onHover { isHovered = $0 }
        .help(tab.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("VaultPaneTabButton.\(tab.rawValue)")
    }
}
