import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleControl<Label: View>: View {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasChatToggle: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        fittedLabel
            .mobileGlassCompactNavigationTitle()
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
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
