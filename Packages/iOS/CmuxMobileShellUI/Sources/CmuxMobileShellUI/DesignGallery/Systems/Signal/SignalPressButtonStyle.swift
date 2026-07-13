#if DEBUG
import SwiftUI

/// Gives Signal buttons a near-square monochrome treatment and crossfade press feedback.
struct SignalPressButtonStyle: ButtonStyle {
    /// The two app-wide Signal action treatments.
    enum Role: Equatable {
        case primary
        case secondary
    }

    let role: Role
    let theme: SignalTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.footnote, design: .monospaced, weight: .semibold))
            .foregroundStyle(role == .primary ? theme.surface : theme.ink)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(role == .primary ? theme.ink : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(role == .secondary ? theme.ink : Color.clear, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(.linear(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
#endif
