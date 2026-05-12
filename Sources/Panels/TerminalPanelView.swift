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

    var body: some View {
        Group {
            if panel.sidekickState.isOpen, let sidekickPanel = panel.sidekickBrowserPanel {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        terminalSurface
                            .frame(
                                width: TerminalSidekickLayout.terminalWidth(
                                    totalWidth: proxy.size.width,
                                    splitRatio: panel.sidekickState.splitRatio
                                )
                            )
                        Rectangle()
                            .fill(appearance.dividerColor.opacity(0.9))
                            .frame(width: TerminalSidekickLayout.dividerWidth)
                        TerminalSidekickView(
                            terminalPanel: panel,
                            browserPanel: sidekickPanel
                        )
                        .frame(
                            width: TerminalSidekickLayout.sidekickWidth(
                                totalWidth: proxy.size.width,
                                splitRatio: panel.sidekickState.splitRatio
                            )
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                terminalSurface
            }
        }
        .animation(.easeInOut(duration: 0.16), value: panel.sidekickState.isOpen)
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

private enum TerminalSidekickLayout {
    static let dividerWidth: CGFloat = 1
    private static let minimumTerminalWidth: CGFloat = 280
    private static let minimumSidekickWidth: CGFloat = 260

    static func sidekickWidth(totalWidth: CGFloat, splitRatio: Double) -> CGFloat {
        guard totalWidth > dividerWidth else { return 0 }
        let availableWidth = max(0, totalWidth - dividerWidth)
        let targetWidth = availableWidth * CGFloat(TerminalSidekickState.clampedSplitRatio(splitRatio))
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

private struct TerminalSidekickView: View {
    @ObservedObject var terminalPanel: TerminalPanel
    @ObservedObject var browserPanel: BrowserPanel
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
            syncAddressFromPanel()
        }
        .onChange(of: browserPanel.currentURL) { _, url in
            terminalPanel.recordSidekickCurrentURL(url)
            guard !addressFocused else { return }
            syncAddressFromPanel()
        }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                addressText = browserPanel.preferredURLStringForOmnibar() ?? addressText
            } else {
                syncAddressFromPanel()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolbarButton(
                systemName: "chevron.left",
                help: String(localized: "browser.goBack", defaultValue: "Go Back"),
                action: { browserPanel.goBack() }
            )
            .disabled(!browserPanel.canGoBack)
            .opacity(browserPanel.canGoBack ? 1 : 0.4)

            toolbarButton(
                systemName: "chevron.right",
                help: String(localized: "browser.goForward", defaultValue: "Go Forward"),
                action: { browserPanel.goForward() }
            )
            .disabled(!browserPanel.canGoForward)
            .opacity(browserPanel.canGoForward ? 1 : 0.4)

            toolbarButton(
                systemName: browserPanel.isLoading ? "xmark" : "arrow.clockwise",
                help: browserPanel.isLoading
                    ? String(localized: "browser.stop", defaultValue: "Stop")
                    : String(localized: "browser.reload", defaultValue: "Reload"),
                action: {
                    if browserPanel.isLoading {
                        browserPanel.stopLoading()
                    } else {
                        browserPanel.reload()
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
                action: { terminalPanel.closeSidekick() }
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        if browserPanel.shouldRenderWebView {
            TerminalSidekickWebViewRepresentable(browserPanel: browserPanel)
                .id(browserPanel.webViewInstanceID)
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
        terminalPanel.navigateSidekick(input: addressText)
        addressFocused = false
    }

    private func syncAddressFromPanel() {
        addressText = browserPanel.preferredURLStringForOmnibar() ?? ""
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
    let browserPanel: BrowserPanel

    func makeNSView(context: Context) -> WKWebView {
        browserPanel.webView
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
