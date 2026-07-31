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
        return label()
            // Terminal and pane-map subtitles have different intrinsic widths.
            // Pin the shared title shell to geometry-derived space so navigating
            // between those endpoints cannot move or resize the toolbar title.
            .frame(width: value.titleWidth, alignment: .leading)
    }
}
