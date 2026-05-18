import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void
    @State private var containerSize: CGSize = .zero
    @State private var sidekickResizeStartRatio: Double?
    @State private var sidekickResizePreviewRatio: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
        }
        .animation(.easeInOut(duration: 0.16), value: panel.sidekickState.isOpen)
    }

    @ViewBuilder
    private var content: some View {
        if panel.sidekickState.isOpen, let sidekickPanel = panel.sidekickBrowserPanel {
            let splitRatio = sidekickResizePreviewRatio ?? panel.sidekickState.splitRatio
            let terminalWidth = TerminalSidekickLayout.terminalWidth(
                totalWidth: containerSize.width,
                splitRatio: splitRatio
            )
            let sidekickWidth = TerminalSidekickLayout.sidekickWidth(
                totalWidth: containerSize.width,
                splitRatio: splitRatio
            )

            HStack(spacing: 0) {
                terminalSurface
                    .frame(width: terminalWidth)
                    .frame(maxHeight: .infinity)
                TerminalSidekickDivider(
                    color: appearance.dividerColor,
                    onDrag: resizeSidekick,
                    onEndDrag: finishSidekickResize
                )
                BrowserPanelView(
                    panel: sidekickPanel,
                    paneId: paneId,
                    isFocused: false,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority + 1,
                    onRequestPanelFocus: onFocus,
                    usesProvidedPaneContext: true,
                    embeddedCloseAction: { panel.closeSidekick() }
                )
                .environment(\.paneDropZone, nil)
                .accessibilityIdentifier("TerminalSidekickDrawer")
                .frame(width: sidekickWidth)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resizeSidekick(translationWidth: CGFloat) {
        guard let resizedSplitRatio = resizedSidekickSplitRatio(translationWidth: translationWidth) else {
            return
        }
        sidekickResizePreviewRatio = resizedSplitRatio
    }

    private func finishSidekickResize(translationWidth: CGFloat) {
        if sidekickResizePreviewRatio == nil {
            resizeSidekick(translationWidth: translationWidth)
        }
        if let sidekickResizePreviewRatio {
            panel.setSidekickSplitRatio(sidekickResizePreviewRatio)
        }
        sidekickResizeStartRatio = nil
        sidekickResizePreviewRatio = nil
    }

    private func resizedSidekickSplitRatio(translationWidth: CGFloat) -> Double? {
        let startRatio = sidekickResizeStartRatio ?? panel.sidekickState.splitRatio
        if sidekickResizeStartRatio == nil {
            sidekickResizeStartRatio = startRatio
        }

        return TerminalSidekickLayout.splitRatio(
            totalWidth: containerSize.width,
            startRatio: startRatio,
            translationWidth: translationWidth
        )
    }

    private var terminalSurface: some View {
        // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
        // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
        GhosttyTerminalView(
            terminalSurface: panel.surface,
            paneId: paneId,
            isActive: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalZPriority: portalPriority,
            showsInactiveOverlay: isSplit && !isFocused,
            showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
            inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
            inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
            searchState: panel.searchState,
            reattachToken: panel.viewReattachToken,
            onFocus: { _ in onFocus() },
            onTriggerFlash: onTriggerFlash
        )
        // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
        // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
        .id(panel.id)
        .background(Color.clear)
    }
}

private enum TerminalSidekickDividerMetrics {
    static let hitWidth = TerminalSidekickLayout.dividerWidth
    static let hairlineWidth: CGFloat = 1
}

enum TerminalSidekickLayout {
    static let dividerWidth: CGFloat = 8
    private static let minimumTerminalWidth: CGFloat = 280
    private static let minimumSidekickWidth: CGFloat = 260

    static func sidekickWidth(totalWidth: CGFloat, splitRatio: Double) -> CGFloat {
        guard totalWidth > dividerWidth else { return 0 }
        let availableWidth = max(0, totalWidth - dividerWidth)
        let targetWidth = availableWidth * CGFloat(TerminalSidekickState.clampedSplitRatio(splitRatio))
        return constrainedSidekickWidth(availableWidth: availableWidth, targetWidth: targetWidth)
    }

    static func splitRatio(
        totalWidth: CGFloat,
        startRatio: Double,
        translationWidth: CGFloat
    ) -> Double? {
        guard totalWidth > dividerWidth else { return nil }
        let availableWidth = max(0, totalWidth - dividerWidth)
        guard availableWidth > 0 else { return nil }

        let startWidth = sidekickWidth(totalWidth: totalWidth, splitRatio: startRatio)
        let resizedWidth = startWidth - translationWidth
        let boundedWidth = constrainedSidekickWidth(
            availableWidth: availableWidth,
            targetWidth: resizedWidth
        )
        return TerminalSidekickState.clampedSplitRatio(Double(boundedWidth / availableWidth))
    }

    private static func constrainedSidekickWidth(
        availableWidth: CGFloat,
        targetWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth >= minimumTerminalWidth + minimumSidekickWidth else {
            return max(0, min(availableWidth, targetWidth))
        }
        let maximumSidekickWidth = availableWidth - minimumTerminalWidth
        return min(maximumSidekickWidth, max(minimumSidekickWidth, targetWidth))
    }

    static func terminalWidth(totalWidth: CGFloat, splitRatio: Double) -> CGFloat {
        max(0, totalWidth - dividerWidth - sidekickWidth(totalWidth: totalWidth, splitRatio: splitRatio))
    }
}

private struct TerminalSidekickDivider: View {
    let color: Color
    let onDrag: (CGFloat) -> Void
    let onEndDrag: (CGFloat) -> Void

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(color.opacity(0.9))
                .frame(width: TerminalSidekickDividerMetrics.hairlineWidth)
        }
        .frame(width: TerminalSidekickDividerMetrics.hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .backport.pointerStyle(.resizeLeftRight)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDrag(value.translation.width)
                }
                .onEnded { value in
                    onEndDrag(value.translation.width)
                }
        )
        .accessibilityIdentifier("TerminalSidekickResizeDivider")
        .accessibilityLabel(String(localized: "terminalSidekick.resizeDivider", defaultValue: "Resize Sidekick"))
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double
    let usesClearContentBackground: Bool

    var contentBackgroundColor: NSColor {
        usesClearContentBackground ? .clear : backgroundColor
    }

    var drawsContentBackground: Bool {
        !usesClearContentBackground
    }

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        fromConfig(config, usesTransparentWindow: cmuxShouldUseTransparentBackgroundWindow())
    }

    static func fromConfig(_ config: GhosttyConfig, usesTransparentWindow: Bool) -> PanelAppearance {
        PanelAppearance(
            backgroundColor: GhosttyBackgroundTheme.color(
                backgroundColor: config.backgroundColor,
                opacity: config.backgroundOpacity
            ),
            foregroundColor: config.foregroundColor,
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity,
            usesClearContentBackground: shouldUseClearContentBackground(
                opacity: config.backgroundOpacity,
                usesGhosttyGlassStyle: config.backgroundBlur.isMacOSGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        )
    }

    static func shouldUseClearContentBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        usesTransparentWindow || usesGhosttyGlassStyle || opacity < 0.999
    }
}
