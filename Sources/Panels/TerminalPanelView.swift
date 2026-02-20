import SwiftUI
import Foundation

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let isSplit: Bool
    let appearance: PanelAppearance
    let notificationStore: TerminalNotificationStore
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let surface = panel.surface {
                GhosttyTerminalView(
                    terminalSurface: surface,
                    isActive: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    reattachToken: panel.viewReattachToken,
                    onFocus: { _ in onFocus() },
                    onTriggerFlash: onTriggerFlash,
                    dimmingColor: appearance.unfocusedOverlayNSColor,
                    dimmingOpacity: (isSplit && !isFocused) ? appearance.unfocusedOverlayOpacity : 0,
                    showNotificationBorder: notificationStore.hasUnreadNotification(forTabId: panel.workspaceId, surfaceId: panel.id),
                    notificationBorderColor: .systemBlue
                )
                // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
                // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
                .id(panel.id)
                .background(Color.clear)
            }

            // Search overlay
            if let searchState = panel.searchState,
               let surface = panel.surface {
                SurfaceSearchOverlay(
                    surface: surface,
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
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}
