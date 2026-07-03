import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View {
    var isEnabled = true
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        MobileToolbarPriorityHost(role: .compressibleTitle) {
            if isEnabled {
                Menu {
                    menuContent()
                } label: {
                    fittedLabel
                }
                .accessibilityIdentifier("MobileWorkspaceTitleMenu")
            } else {
                Button {} label: {
                    fittedLabel
                }
                .allowsHitTesting(false)
                .accessibilityRemoveTraits(.isButton)
                .accessibilityIdentifier("MobileWorkspaceTitleMenu")
            }
        }
    }

    private var fittedLabel: some View {
        label()
            .layoutPriority(MobileToolbarItemLayoutRole.compressibleTitle.swiftUILayoutPriority)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
            .clipped()
    }
}
