#if os(iOS)
import SwiftUI

/// Adds restrained touch-down feedback to terminal artifact gallery items.
struct TerminalArtifactGalleryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.07 : 0))
            }
    }
}
#endif
