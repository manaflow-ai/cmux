import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View {
    var isEnabled = true
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        if isEnabled {
            Menu {
                menuContent()
            } label: {
                menuLabel
            }
            .mobileGlassCompactToolbarControl()
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        } else {
            Button {} label: {
                menuLabel
            }
            .mobileGlassCompactToolbarControl()
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityIdentifier("MobileWorkspaceTitleMenu")
        }
    }

    private var menuLabel: some View {
        label()
            .frame(minWidth: 0, alignment: .leading)
    }
}
