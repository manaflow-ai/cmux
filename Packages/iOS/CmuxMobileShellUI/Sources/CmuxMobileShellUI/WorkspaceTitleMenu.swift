import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasChatToggle: Bool
    var isEnabled = true
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        if isEnabled {
            Menu {
                menuContent()
            } label: {
                fittedLabel
            }
            .mobileGlassCompactToolbarControl()
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        } else {
            fittedLabel
                .mobileGlassCompactNavigationTitle()
                .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        }
    }

    private var fittedLabel: some View {
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
}
