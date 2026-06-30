import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleControl<Label: View>: View {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        fittedLabel
            .mobileGlassCompactNavigationTitle()
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
    }

    private var fittedLabel: some View {
        let cap = MobileNavTitleWidth(
            contentWidth: contentWidth,
            hasBackButton: hasBackButton,
            hasTrailingCluster: hasTrailingCluster,
            hasChatToggle: hasChatToggle
        ).cap

        return label()
            .frame(
                minWidth: min(MobileNavTitleWidth.floor, cap),
                maxWidth: cap,
                alignment: .leading
            )
            .layoutPriority(1)
    }
}
