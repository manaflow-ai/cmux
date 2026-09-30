import SwiftUI

struct WorkspaceAttentionFlashRingView: View {
    @Environment(\.workspaceAttentionColor) private var workspaceAttentionColor

    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation

    var body: some View {
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let color = Color(nsColor: workspaceAttentionColor.nsColor)

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
