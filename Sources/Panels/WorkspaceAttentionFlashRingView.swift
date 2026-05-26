import AppKit
import SwiftUI

struct WorkspaceAttentionFlashRingView: View {
    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation
    var windowCornerRadius: CGFloat?
    @Environment(\.cmuxWindowCornerRadius) private var environmentWindowCornerRadius

    var body: some View {
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let color = Color(nsColor: presentation.accent.strokeColor)
        let cornerRadius = PanelOverlayRingMetrics.cornerRadius(
            forWindowCornerRadius: windowCornerRadius ?? environmentWindowCornerRadius
        )

        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(color.opacity(opacity), lineWidth: PanelOverlayRingMetrics.lineWidth)
            .shadow(
                color: color.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
            .padding(CGFloat(FocusFlashPattern.ringInset))
            .allowsHitTesting(false)
    }
}

private struct CmuxWindowCornerRadiusEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var cmuxWindowCornerRadius: CGFloat? {
        get { self[CmuxWindowCornerRadiusEnvironmentKey.self] }
        set { self[CmuxWindowCornerRadiusEnvironmentKey.self] = newValue }
    }
}
