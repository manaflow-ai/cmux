import SwiftUI

struct OmnibarAddressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OmnibarAddressButtonStyleBody(configuration: configuration)
    }
}

private struct OmnibarAddressButtonStyleBody: View {
    let configuration: OmnibarAddressButtonStyle.Configuration

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
