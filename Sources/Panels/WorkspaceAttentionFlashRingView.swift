import CmuxSettings
import CmuxSettingsUI
import SwiftUI

struct WorkspaceAttentionFlashRingView: View {
    @LiveSetting(\.notifications.paneFlashColorHex) private var paneFlashColorHex

    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation

    var body: some View {
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let color = Color(
            nsColor: presentation.accent.resolvedColor(configuredHex: paneFlashColorHex).nsColor
        )

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
