import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View, Equatable {
    let value: WorkspaceTitleMenuValue
    /// In the owned top bar the row's own layout hands the title exactly the
    /// leftover width (fixed pills first, title truncates), so the
    /// estimate-based cap is skipped entirely. The system-toolbar path keeps
    /// the cap: there the system arbitrates item overflow and the title must
    /// never claim the trailing items' space.
    var usesNaturalWidth: Bool = false
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
