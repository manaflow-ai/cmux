import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View, Equatable {
    let value: WorkspaceTitleMenuValue
    /// Reports the fitted label's leading edge in global space so the host
    /// can derive the realized title-to-trailing span. Not part of equality:
    /// geometry callbacks re-fire on layout changes regardless.
    var onLabelLeadingEdgeChange: ((CGFloat) -> Void)? = nil
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
            hasChatToggle: value.hasChatToggle,
            measuredTrailingItemsWidth: value.measuredTrailingItemsWidth,
            measuredTrailingItemCount: value.measuredTrailingItemCount,
            trailingItemCount: value.trailingItemCount,
            measuredTitleToTrailingSpan: value.measuredTitleToTrailingSpan
        ).cap

        return label()
            .frame(
                minWidth: min(MobileLeadingToolbarTitleWidth.floor, cap),
                maxWidth: cap,
                alignment: .leading
            )
            // The frame is leading-aligned, so its leading edge does not move
            // as the cap grows; reporting it cannot feed back into the cap.
            .measureToolbarTitleFrame { frame in
                onLabelLeadingEdgeChange?(frame.minX)
            }
    }
}
