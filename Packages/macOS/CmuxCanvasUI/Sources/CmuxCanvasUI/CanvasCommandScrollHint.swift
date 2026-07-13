import CmuxFoundation
import SwiftUI

/// The one-time discovery hint that appears, with a soft scale+fade, after a
/// user scrolls inside a pane: it teaches that Command+scroll pans the canvas
/// from anywhere. Pure presentation; lifecycle (debounce, auto-dismiss) is
/// owned by `CanvasRootView`. Text is pre-localized by the host SwiftUI
/// layer's default value here since the package owns no catalogs.
struct CanvasCommandScrollHint: View {
    /// Pre-localized hint text, supplied by the host.
    let text: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            textKeycap("⌘")
            Image(systemName: "plus")
                .cmuxFont(size: 9, weight: .bold)
                .foregroundStyle(.secondary)
            symbolKeycap("arrow.up.and.down.and.arrow.left.and.right")
            Text(text)
                .cmuxFont(size: 12, weight: .medium)
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .scaleEffect(shown ? 1 : 0.9)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                shown = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(text)
    }

    private func textKeycap(_ text: String) -> some View {
        keycapContainer {
            Text(text)
                .cmuxFont(size: 12, weight: .semibold)
        }
    }

    private func symbolKeycap(_ systemName: String) -> some View {
        keycapContainer {
            Image(systemName: systemName)
                .cmuxFont(size: 12, weight: .semibold)
        }
    }

    private func keycapContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.primary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}
