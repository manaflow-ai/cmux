import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View, Equatable {
    let value: WorkspaceTitleMenuValue
    /// The regular-width iPad detail bar owns its layout, so the title should
    /// consume the space left by the fixed controls instead of participating in
    /// the system toolbar's overflow estimate.
    var usesNaturalWidth = false
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value && lhs.usesNaturalWidth == rhs.usesNaturalWidth
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

    @ViewBuilder
    private var fittedLabel: some View {
        if usesNaturalWidth {
            label()
        } else {
            cappedLabel
        }
    }

    private var cappedLabel: some View {
        let cap = MobileLeadingToolbarTitleWidth(
            contentWidth: value.contentWidth,
            hasBackButton: value.hasBackButton,
            hasTrailingCluster: value.hasTrailingCluster,
            measuredTrailingItemsWidth: value.measuredTrailingItemsWidth,
            measuredTrailingItemCount: value.measuredTrailingItemCount,
            trailingItemCount: value.trailingItemCount,
            hadTrailingCollapse: value.hadTrailingCollapse
        ).cap

        return label()
            .frame(
                minWidth: min(MobileLeadingToolbarTitleWidth.floor, cap),
                maxWidth: cap,
                alignment: .leading
            )
    }
}
