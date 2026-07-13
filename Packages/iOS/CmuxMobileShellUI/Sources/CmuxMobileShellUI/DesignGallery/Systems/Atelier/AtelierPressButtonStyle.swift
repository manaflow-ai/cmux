#if DEBUG
import SwiftUI

/// Gives Atelier controls a gentle spring press without changing their visual language.
struct AtelierPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.25)
                    : .spring(response: 0.5, dampingFraction: 0.85),
                value: configuration.isPressed
            )
    }
}
#endif
