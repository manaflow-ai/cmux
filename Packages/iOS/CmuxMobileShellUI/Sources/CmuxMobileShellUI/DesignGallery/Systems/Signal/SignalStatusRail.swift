#if DEBUG
import SwiftUI

/// Draws a two-point status rail with the running-only linear shimmer.
struct SignalStatusRail: View {
    let style: SignalStatusStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase = 0.0

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(style.color.opacity(style.isRunning ? 0.34 : 1.0))
                .overlay(alignment: .top) {
                    if style.isRunning {
                        Rectangle()
                            .fill(style.color)
                            .frame(height: max(10, proxy.size.height * 0.32))
                            .offset(y: reduceMotion ? proxy.size.height * 0.34 : (-proxy.size.height * 0.32) + (proxy.size.height * 1.32 * shimmerPhase))
                    }
                }
                .clipped()
        }
        .frame(width: 2)
        .onAppear {
            guard style.isRunning, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduce in
            if shouldReduce {
                withAnimation(.linear(duration: 0.12)) {
                    shimmerPhase = 0
                }
            } else if style.isRunning {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
