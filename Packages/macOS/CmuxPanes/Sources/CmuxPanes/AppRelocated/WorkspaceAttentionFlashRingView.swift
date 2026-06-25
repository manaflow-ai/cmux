import CmuxPanes
import SwiftUI

struct WorkspaceAttentionFlashRingView: View {
    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation

    var body: some View {
        let presentation = WorkspaceAttentionFlashPresentation.flashRing(for: reason)
        let color = Color(nsColor: presentation.accent.strokeColor)

        RoundedRectangle(cornerRadius: CGFloat(FocusFlashPattern.ringCornerRadius))
            .stroke(color.opacity(opacity), lineWidth: PanelOverlayRingMetrics.lineWidth)
            .shadow(
                color: color.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
            .padding(CGFloat(FocusFlashPattern.ringInset))
            .allowsHitTesting(false)
    }
}
