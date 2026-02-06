import SwiftUI
import Foundation

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    let isFocused: Bool
    let isSplit: Bool
    let appearance: PanelAppearance
    let notificationStore: TerminalNotificationStore
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                isActive: isFocused,
                onFocus: { _ in onFocus() },
                onTriggerFlash: onTriggerFlash
            )
            .background(Color.clear)

            // Unfocused overlay
            if isSplit && !isFocused && appearance.unfocusedOverlayOpacity > 0 {
                Rectangle()
                    .fill(appearance.unfocusedOverlayColor)
                    .opacity(appearance.unfocusedOverlayOpacity)
                    .allowsHitTesting(false)
            }

            // Unread notification indicator
            if notificationStore.hasUnreadNotification(forTabId: panel.workspaceId, surfaceId: panel.id) {
                Rectangle()
                    .stroke(Color(nsColor: .systemBlue), lineWidth: 2.5)
                    .shadow(color: Color(nsColor: .systemBlue).opacity(0.35), radius: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }

            // Search overlay
            if let searchState = panel.searchState {
                SurfaceSearchOverlay(
                    surface: panel.surface,
                    searchState: searchState,
                    onClose: {
                        panel.searchState = nil
                        panel.hostedView.moveFocus()
                    }
                )
            }
        }
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let dividerColor: Color
    let unfocusedOverlayColor: Color
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayColor: Color(nsColor: config.unfocusedSplitOverlayFill),
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}
