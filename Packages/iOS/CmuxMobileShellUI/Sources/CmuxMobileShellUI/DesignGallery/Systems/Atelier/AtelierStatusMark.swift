#if DEBUG
import SwiftUI

/// Displays state with color, symbol, and a plain-language word label.
struct AtelierStatusMark: View {
    let state: GalleryAgentState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isBreathing = false

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)
        let statusColor = theme.color(for: state)

        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 20, height: 20)
                Image(systemName: theme.symbol(for: state))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusColor)
            }
            .scaleEffect(state == .running && isBreathing && !reduceMotion ? 1.15 : 1)
            .animation(
                reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 3).repeatForever(autoreverses: true),
                value: isBreathing
            )

            Text(theme.label(for: state))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .onAppear {
            if state == .running && !reduceMotion {
                isBreathing = true
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduce in
            isBreathing = state == .running && !shouldReduce
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
