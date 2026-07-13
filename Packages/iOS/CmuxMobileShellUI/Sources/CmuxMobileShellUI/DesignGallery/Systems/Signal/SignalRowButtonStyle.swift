#if DEBUG
import SwiftUI

/// Adds a restrained 120-millisecond opacity response to tappable Signal rows.
struct SignalRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.56 : 1)
            .animation(.linear(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
