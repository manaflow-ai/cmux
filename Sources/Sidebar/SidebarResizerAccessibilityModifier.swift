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
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }

    private var accessibilityLabel: String {
        if accessibilityIdentifier == "RightSidebarResizer" {
            return String(localized: "rightSidebar.resizer.accessibilityLabel", defaultValue: "Resize right sidebar")
        }
        return String(localized: "sidebar.resizer.accessibilityLabel", defaultValue: "Resize sidebar")
    }
}
