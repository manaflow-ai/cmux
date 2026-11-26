import SwiftUI

/// Exposes each sidebar divider as an element without altering its drag target.
struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content
                // A clear shape with a gesture is otherwise omitted from the accessibility tree.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.allowsDirectInteraction)
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}
