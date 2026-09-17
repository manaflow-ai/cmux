import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View, Equatable {
    let value: WorkspaceTitleMenuValue
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    @ViewBuilder
    var body: some View {
        if value.isEnabled {
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

    private var fittedLabel: some View {
        let cap = MobileLeadingToolbarTitleWidth(
            contentWidth: value.contentWidth,
            hasBackButton: value.hasBackButton,
            hasTrailingCluster: value.hasTrailingCluster,
            hasChatToggle: value.hasChatToggle
        ).cap

        return label()
            .frame(
                minWidth: min(MobileLeadingToolbarTitleWidth.floor, cap),
                maxWidth: cap,
                alignment: .leading
            )
    }
}
