#if DEBUG
import SwiftUI

/// Gives inert gallery buttons a tactile press response while honoring Reduce Motion.
struct MeridianPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .spring(), value: configuration.isPressed)
    }
}
#endif
