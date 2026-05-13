import SwiftUI
import Foundation
import AppKit
import Bonsplit
import WebKit

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
                TerminalSidekickView(
                    snapshot: TerminalSidekickBrowserSnapshot(browserPanel: sidekickPanel),
                    webView: sidekickPanel.webView,
                    onGoBack: { sidekickPanel.goBack() },
                    onGoForward: { sidekickPanel.goForward() },
                    onReload: { sidekickPanel.reload() },
                    onStopLoading: { sidekickPanel.stopLoading() },
                    onNavigate: { panel.navigateSidekick(input: $0) },
                    onRecordCurrentURL: { panel.recordSidekickCurrentURL($0) },
                    onClose: { panel.closeSidekick() }
                )
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

private struct TerminalSidekickBrowserSnapshot: Equatable {
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let shouldRenderWebView: Bool
    let currentURL: URL?
    let preferredAddressText: String?
    let webViewInstanceID: UUID

    @MainActor
    init(browserPanel: BrowserPanel) {
        self.canGoBack = browserPanel.canGoBack
        self.canGoForward = browserPanel.canGoForward
        self.isLoading = browserPanel.isLoading
        self.shouldRenderWebView = browserPanel.shouldRenderWebView
        self.currentURL = browserPanel.currentURL
        self.preferredAddressText = browserPanel.preferredURLStringForOmnibar()
        self.webViewInstanceID = browserPanel.webViewInstanceID
    }
}

private struct TerminalSidekickView: View {
    let snapshot: TerminalSidekickBrowserSnapshot
    let webView: WKWebView
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onReload: () -> Void
    let onStopLoading: () -> Void
    let onNavigate: (String) -> Void
    let onRecordCurrentURL: (URL?) -> Void
    let onClose: () -> Void
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private let toolbarButtonSize: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("TerminalSidekickDrawer")
        .accessibilityLabel(String(localized: "terminalSidekick.accessibilityLabel", defaultValue: "Terminal sidekick browser"))
        .onAppear {
            syncAddressFromSnapshot()
        }
        .onChange(of: snapshot.currentURL) { _, url in
            onRecordCurrentURL(url)
            guard !addressFocused else { return }
            syncAddressFromSnapshot()
        }
        .onChange(of: snapshot.preferredAddressText) { _, _ in
            guard !addressFocused else { return }
            syncAddressFromSnapshot()
        }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                addressText = snapshot.preferredAddressText ?? addressText
            } else {
                syncAddressFromSnapshot()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolbarButton(
                systemName: "chevron.left",
                help: String(localized: "browser.goBack", defaultValue: "Go Back"),
                action: onGoBack
            )
            .disabled(!snapshot.canGoBack)
            .opacity(snapshot.canGoBack ? 1 : 0.4)

            toolbarButton(
                systemName: "chevron.right",
                help: String(localized: "browser.goForward", defaultValue: "Go Forward"),
                action: onGoForward
            )
            .disabled(!snapshot.canGoForward)
            .opacity(snapshot.canGoForward ? 1 : 0.4)

            toolbarButton(
                systemName: snapshot.isLoading ? "xmark" : "arrow.clockwise",
                help: snapshot.isLoading
                    ? String(localized: "browser.stop", defaultValue: "Stop")
                    : String(localized: "browser.reload", defaultValue: "Reload"),
                action: {
                    if snapshot.isLoading {
                        onStopLoading()
                    } else {
                        onReload()
                    }
                }
            )

            TextField(
                String(localized: "terminalSidekick.addressPlaceholder", defaultValue: "Enter URL or search"),
                text: $addressText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($addressFocused)
            .onSubmit(commitAddress)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .accessibilityIdentifier("TerminalSidekickAddressField")
            .accessibilityLabel(String(localized: "terminalSidekick.addressLabel", defaultValue: "Sidekick address"))

            toolbarButton(
                systemName: "arrow.right.circle.fill",
                help: String(localized: "terminalSidekick.open", defaultValue: "Open in Sidekick"),
                action: commitAddress
            )
            .disabled(addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

            toolbarButton(
                systemName: "sidebar.trailing",
                help: String(localized: "terminalSidekick.collapse", defaultValue: "Collapse Sidekick"),
                action: onClose
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        if snapshot.shouldRenderWebView {
            TerminalSidekickWebViewRepresentable(webView: webView)
                .id(snapshot.webViewInstanceID)
                .accessibilityIdentifier("TerminalSidekickWebView")
        } else {
            Color(nsColor: .textBackgroundColor)
                .accessibilityIdentifier("TerminalSidekickBlankWebView")
        }
    }

    private func toolbarButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: toolbarButtonSize, height: toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(TerminalSidekickToolbarButtonStyle())
        .safeHelp(help)
    }

    private func commitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onNavigate(trimmed)
        addressFocused = false
    }

    private func syncAddressFromSnapshot() {
        addressText = snapshot.preferredAddressText ?? ""
    }
}

private struct TerminalSidekickToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.65 : 0.9))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            )
    }
}

private struct TerminalSidekickWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.allowsBackForwardNavigationGestures = true
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            backgroundColor: GhosttyBackgroundTheme.color(
                backgroundColor: config.backgroundColor,
                opacity: config.backgroundOpacity
            ),
            foregroundColor: config.foregroundColor,
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}
