import SwiftUI
import Foundation
import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxNotifications
import CmuxPanes
import CmuxTestSupport
import CmuxTerminal
import CmuxFoundation

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    @AppStorage(TerminalTextBoxInputSettings.maxLinesKey)
    private var textBoxMaxLines = TerminalTextBoxInputSettings.defaultMaxLines
    @State private var terminalFontSize = GhosttyConfig.load().fontSize
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    let onFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        if let hibernationState = panel.agentHibernationState {
            hibernationBody(hibernationState)
        } else {
            terminalBody
        }
    }

    @ViewBuilder
    private func hibernationBody(_ hibernationState: AgentHibernationPanelState) -> some View {
        if isVisibleInUI {
            Color(nsColor: appearance.contentBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("hibernated-resuming-\(panel.id.uuidString)")
                .onAppear {
                    onAutoResumeAgentHibernation()
                }
        } else {
            AgentHibernationPlaceholderView(
                state: hibernationState,
                appearance: appearance,
                onResume: onResumeAgentHibernation
            )
            .id("hibernated-\(panel.id.uuidString)")
            .onChange(of: isVisibleInUI) { _, visible in
                if visible {
                    onAutoResumeAgentHibernation()
                }
            }
        }
    }

    private var terminalBody: some View {
        VStack(spacing: 0) {
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
                onFocus: { _ in
                    panel.terminalDidBecomeFocused()
                    onFocus()
                },
                onTriggerFlash: onTriggerFlash
            )
            // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
            // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
            .id(panel.id)
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
            .reportTerminalViewportGeometryForUITest(panel: panel)
#endif
            .layoutPriority(1)

            if panel.isTextBoxActive {
                TextBoxInputContainer(
                    text: $panel.textBoxContent,
                    attachments: $panel.textBoxAttachments,
                    surface: panel.surface,
                    terminalBackgroundColor: appearance.backgroundColor,
                    terminalForegroundColor: appearance.foregroundColor,
                    terminalFont: NSFont.monospacedSystemFont(
                        ofSize: terminalFontSize,
                        weight: .regular
                    ),
                    maxLines: TerminalTextBoxInputSettings.resolvedMaxLines(textBoxMaxLines),
                    terminalAgentContext: terminalAgentContext,
                    onFocusTextBox: {
                        panel.textBoxDidBecomeFocused()
                        onFocus()
                    },
                    onToggleFocus: {
                        _ = panel.focusTextBoxInputOrTerminal()
                    },
                    onEscape: {
                        panel.handleTextBoxEscape()
                    },
                    onTextViewCreated: { view in
                        panel.registerTextBoxInputView(view)
                    },
                    onTextViewMovedToWindow: { view in
                        panel.textBoxInputViewDidMoveToWindow(view)
                    },
                    onTextViewDismantled: { view in
                        panel.preserveTextBoxContentForUnmount(from: view)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            terminalFontSize = GhosttyConfig.load().fontSize
        }
    }
}

private struct AgentHibernationPlaceholderView: View {
    let state: AgentHibernationPanelState
    let appearance: PanelAppearance
    let onResume: () -> Void

    private var lastActivityText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: state.lastActivityAt, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pause.circle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(String(localized: "terminal.agentHibernation.title", defaultValue: "Agent hibernated"))
                    .font(.headline)
                Text(state.agentDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "terminal.agentHibernation.lastActivity", defaultValue: "Last activity %@"),
                        lastActivityText
                    )
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Button(String(localized: "terminal.agentHibernation.resume", defaultValue: "Resume")) {
                onResume()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("AgentHibernationResumeButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}

#if DEBUG
private extension View {
    func reportTerminalViewportGeometryForUITest(panel: TerminalPanel) -> some View {
        modifier(TerminalViewportGeometryReporter(panel: panel))
    }
}

private struct TerminalViewportGeometryReporter: ViewModifier {
    @ObservedObject var panel: TerminalPanel

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        recordTerminalViewportGeometryForUITest(proxy: proxy, panel: panel)
                    }
                    .onChange(of: proxy.size) {
                        recordTerminalViewportGeometryForUITest(proxy: proxy, panel: panel)
                    }
            }
        }
    }
}

@MainActor
private func recordTerminalViewportGeometryForUITest(proxy: GeometryProxy, panel: TerminalPanel) {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return
    }

    let hostedView = panel.hostedView
    let hostedFrame = hostedView.frame
    let hostedBounds = hostedView.bounds
    let hostedSuperviewBounds = hostedView.superview?.bounds ?? .zero
    let windowContentBounds = hostedView.window?.contentView?.bounds ?? .zero
    let hostedFrameInContent: NSRect
    if let contentView = hostedView.window?.contentView {
        hostedFrameInContent = contentView.convert(hostedView.convert(hostedView.bounds, to: nil), from: nil)
    } else {
        hostedFrameInContent = .zero
    }

    _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH") { payload in
        payload["terminalViewportPanelId"] = panel.id.uuidString
        payload["terminalViewportPanelWidth"] = terminalViewportFormat(proxy.size.width)
        payload["terminalViewportPanelHeight"] = terminalViewportFormat(proxy.size.height)
        payload["terminalViewportHostedFrameMinX"] = terminalViewportFormat(hostedFrame.minX)
        payload["terminalViewportHostedFrameMinY"] = terminalViewportFormat(hostedFrame.minY)
        payload["terminalViewportHostedFrameMaxX"] = terminalViewportFormat(hostedFrame.maxX)
        payload["terminalViewportHostedFrameMaxY"] = terminalViewportFormat(hostedFrame.maxY)
        payload["terminalViewportHostedFrameWidth"] = terminalViewportFormat(hostedFrame.width)
        payload["terminalViewportHostedFrameHeight"] = terminalViewportFormat(hostedFrame.height)
        payload["terminalViewportHostedBoundsWidth"] = terminalViewportFormat(hostedBounds.width)
        payload["terminalViewportHostedBoundsHeight"] = terminalViewportFormat(hostedBounds.height)
        payload["terminalViewportHostedSuperviewWidth"] = terminalViewportFormat(hostedSuperviewBounds.width)
        payload["terminalViewportHostedSuperviewHeight"] = terminalViewportFormat(hostedSuperviewBounds.height)
        payload["terminalViewportWindowContentWidth"] = terminalViewportFormat(windowContentBounds.width)
        payload["terminalViewportWindowContentHeight"] = terminalViewportFormat(windowContentBounds.height)
        payload["terminalViewportHostedContentMinX"] = terminalViewportFormat(hostedFrameInContent.minX)
        payload["terminalViewportHostedContentMinY"] = terminalViewportFormat(hostedFrameInContent.minY)
        payload["terminalViewportHostedContentMaxX"] = terminalViewportFormat(hostedFrameInContent.maxX)
        payload["terminalViewportHostedContentMaxY"] = terminalViewportFormat(hostedFrameInContent.maxY)
    }
}

private func terminalViewportFormat(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}
#endif

// App-side factories that resolve a `PanelAppearance` (a package value type in
// CmuxPanes) from a Ghostty config. These stay in the app target because they
// read the app-owned window-background composition policy, the Ghostty
// background theme, and the readable-foreground color helper, none of which
// belong in the panel package.
extension PanelAppearance {
    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        fromConfig(
            config,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: false)
        )
    }

    static func fromConfig(_ config: GhosttyConfig, usesTransparentWindow: Bool) -> PanelAppearance {
        let backgroundColor = GhosttyBackgroundTheme.color(
            backgroundColor: config.backgroundColor,
            opacity: config.backgroundOpacity
        )
        return PanelAppearance(
            backgroundColor: backgroundColor,
            foregroundColor: cmuxReadableForegroundNSColor(
                preferred: config.foregroundColor,
                on: backgroundColor
            ),
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
}
