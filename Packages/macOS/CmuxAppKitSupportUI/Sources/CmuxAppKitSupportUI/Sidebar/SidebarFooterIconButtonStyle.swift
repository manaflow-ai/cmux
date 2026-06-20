public import SwiftUI

/// A button style for sidebar footer icon buttons that draws a rounded hover/press
/// highlight behind the label.
///
/// The highlight is transparent at rest, lightly tinted on hover, and more strongly
/// tinted while pressed; it is fully suppressed when the button is disabled. The
/// hover and press transitions are eased independently.
public struct SidebarFooterIconButtonStyle: ButtonStyle {
    /// Creates a sidebar footer icon button style.
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

/// The rendering body for ``SidebarFooterIconButtonStyle``.
///
/// Kept as a dedicated `View` so the hover state has its own `@State` storage and the
/// background opacity derives from the live hover, press, and enabled state.
struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
