import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasChatToggle: Bool
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            menuContent()
        } label: {
            label()
                .frame(
                    minWidth: MobileNavTitleWidth.floor,
                    maxWidth: MobileNavTitleWidth(
                        contentWidth: contentWidth,
                        hasBackButton: hasBackButton,
                        hasChatToggle: hasChatToggle
                    ).leadingCap,
                    alignment: .leading
                )
                .layoutPriority(1)
        }
        .mobileGlassCompactToolbarControl()
        .accessibilityIdentifier("MobileWorkspaceTitleMenu")
    }
}
