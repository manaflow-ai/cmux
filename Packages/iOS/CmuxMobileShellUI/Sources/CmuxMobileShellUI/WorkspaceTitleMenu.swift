import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleControl<Label: View>: View {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasChatToggle: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Button {} label: {
                fittedLabel
            }
            .mobileGlassCompactToolbarControl()
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        } else {
            fittedLabel
                .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        }
        #else
        fittedLabel
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        #endif
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
