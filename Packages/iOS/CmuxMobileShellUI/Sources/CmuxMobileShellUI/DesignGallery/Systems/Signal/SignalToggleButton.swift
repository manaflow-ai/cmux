#if DEBUG
import SwiftUI

/// Provides a monochrome 44-point Settings toggle without decorative signal color.
struct SignalToggleButton: View {
    @Binding var isOn: Bool
    let theme: SignalTheme

    var body: some View {
        Button {
            withAnimation(.linear(duration: 0.12)) {
                isOn.toggle()
            }
        } label: {
            Text(isOn ? "ON" : "OFF")
        }
        .buttonStyle(SignalPressButtonStyle(
            role: isOn ? .primary : .secondary,
            theme: theme
        ))
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
#endif
