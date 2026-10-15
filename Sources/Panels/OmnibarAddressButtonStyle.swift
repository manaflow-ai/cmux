import SwiftUI

struct OmnibarAddressButtonStyle: ButtonStyle {
    /// Shows the pressed fill while something the button opened stays open
    /// (an extension popup). Off by default, so existing buttons are unchanged.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        OmnibarAddressButtonStyleBody(configuration: configuration, isActive: isActive)
    }
}

private struct OmnibarAddressButtonStyleBody: View {
    let configuration: OmnibarAddressButtonStyle.Configuration
    let isActive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed || isActive { return 0.16 }
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
            .chromeRevealAnimation(isVisible: isHovered, fadeOut: .easeOut(duration: 0.12))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
