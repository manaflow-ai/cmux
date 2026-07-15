#if DEBUG
import SwiftUI

/// Displays Meridian's symbol-and-color status encoding, including the running pulse.
struct MeridianStatusSymbol: View {
    let state: GalleryAgentState
    var font: Font = .body

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulseActive = false

    var body: some View {
        Image(systemName: theme.symbolName(for: state))
            .font(font)
            .foregroundStyle(theme.color(for: state))
            .symbolEffect(.pulse, options: .repeating, isActive: pulseActive)
            .accessibilityLabel(theme.label(for: state))
            .onAppear {
                pulseActive = isRunning && !reduceMotion
            }
            .onChange(of: reduceMotion) { _, newValue in
                pulseActive = isRunning && !newValue
            }
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var isRunning: Bool {
        state == .running
    }
}
#endif
