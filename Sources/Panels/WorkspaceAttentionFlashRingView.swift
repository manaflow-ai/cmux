import AppKit
import SwiftUI

struct WorkspaceAttentionFlashRingView: View {
    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation
    @State private var windowCornerRadius: CGFloat?

    var body: some View {
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let color = Color(nsColor: presentation.accent.strokeColor)
        let cornerRadius = PanelOverlayRingMetrics.cornerRadius(forWindowCornerRadius: windowCornerRadius)

        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(color.opacity(opacity), lineWidth: PanelOverlayRingMetrics.lineWidth)
            .shadow(
                color: color.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
            .padding(CGFloat(FocusFlashPattern.ringInset))
            .allowsHitTesting(false)
            .background(WindowAccessor(dedupeByWindow: false) { window in
                updateWindowCornerRadius(from: window)
            })
    }

    private func updateWindowCornerRadius(from window: NSWindow) {
        let radius = WindowGlassEffect.windowCornerRadius(for: window)
        guard windowCornerRadius != radius else { return }
        windowCornerRadius = radius
    }
}
