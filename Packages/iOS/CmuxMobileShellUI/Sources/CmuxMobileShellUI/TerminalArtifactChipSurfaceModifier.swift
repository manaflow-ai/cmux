#if os(iOS)
import SwiftUI

/// Gives the terminal artifact chip a quiet native control surface.
struct TerminalArtifactChipSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
            }
    }
}
#endif
