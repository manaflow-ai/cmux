import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View, Equatable {
    let value: WorkspaceTitleMenuValue
    /// The app-owned detail bar lays out its fixed controls, so the title can
    /// use the explicit cap for the current size class and item count.
    var maximumWidth: CGFloat?
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
            && lhs.maximumWidth == rhs.maximumWidth
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
        if let maximumWidth {
            label()
                .frame(maxWidth: maximumWidth, alignment: .leading)
        } else {
            label()
        }
    }
}
