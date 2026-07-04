import SwiftUI
import Foundation
import AppKit
import Bonsplit
import CmuxAppKitSupportUI
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
    @State private var terminalFontSize = GhosttyConfig.load(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent).fontSize
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
        Group {
            if let hibernationState = panel.agentHibernationState {
                hibernationBody(hibernationState)
            } else {
                terminalBody
            }
        }
        .overlay {
            hibernatedActivePaneBoundaryOverlay
        }
    }

    @ViewBuilder
    private var hibernatedActivePaneBoundaryOverlay: some View {
        if panel.agentHibernationState != nil,
           let activePaneBoundaryColor = appearance.activePaneBoundaryColor,
           isSplit && isFocused && isVisibleInUI {
            Rectangle()
                .strokeBorder(activePaneBoundaryColor, lineWidth: activeBoundaryLineWidth)
                .allowsHitTesting(false)
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
        @Bindable var textBoxState = panel.textBoxState

        return VStack(spacing: 0) {
            // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
            // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                paneId: paneId,
                isActive: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalZPriority: portalPriority,
                showsInactiveOverlay: isSplit && !isFocused,
                showsActivePaneBoundary: isSplit && isFocused && isVisibleInUI && appearance.activePaneBoundaryNSColor != nil,
                activePaneBoundaryColor: appearance.activePaneBoundaryNSColor ?? .clear,
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
                    selectedSubmitActionID: $textBoxState.selectedSubmitActionID,
                    pendingProviderLaunchAction: $textBoxState.pendingProviderLaunchAction,
                    pendingProviderLaunchStartedAt: $textBoxState.pendingProviderLaunchStartedAt,
                    surface: panel.surface,
                    terminalBackgroundColor: appearance.backgroundColor,
                    terminalForegroundColor: appearance.foregroundColor,
                    terminalFont: NSFont.monospacedSystemFont(
                        ofSize: terminalFontSize,
                        weight: .regular
                    ),
                    maxLines: TerminalTextBoxInputSettings.resolvedMaxLines(textBoxMaxLines),
                    terminalAgentContext: effectiveTerminalAgentContext,
                    shellActivityState: panel.shellActivity.state,
                    allowsCommandTemplateSubmit: TextBoxInputContainer.allowsCommandTemplateSubmit(
                        shellActivityState: panel.shellActivity.state
                    ),
                    onFocusTextBox: {
                        panel.textBoxDidBecomeFocused()
                        onFocus()
                    },
                    onToggleFocus: {
                        _ = panel.focusTextBoxInputOrTerminal()
                    },
                    onRecordLaunchCommand: { command in
                        panel.recordTextBoxLaunchCommand(command)
                    },
                    onClearLaunchCommand: {
                        panel.clearTextBoxLaunchCommand()
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
                .overlay {
                    terminalTextBoxActivePaneBoundaryOverlay
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            terminalFontSize = GhosttyConfig.load(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent).fontSize
        }
    }

    private var effectiveTerminalAgentContext: String {
        Self.effectiveTerminalAgentContext(
            terminalAgentContext,
            pendingLaunchCommand: panel.textBoxState.pendingLaunchCommand
        )
    }

    static func effectiveTerminalAgentContext(
        _ terminalAgentContext: String,
        pendingLaunchCommand: String?
    ) -> String {
        var context = terminalAgentContext
        appendTextBoxLaunchContext(
            "textBoxPendingLaunchCommand:",
            command: pendingLaunchCommand,
            to: &context
        )
        return context
    }

    private static func appendTextBoxLaunchContext(
        _ prefix: String,
        command: String?,
        to context: inout String
    ) {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return }
        let marker = "\(prefix)\(command)"
        let existingLines = context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !existingLines.contains(marker) else { return }
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context = marker
        } else {
            context += "\n\(marker)"
        }
    }

    @ViewBuilder
    private var terminalTextBoxActivePaneBoundaryOverlay: some View {
        if panel.isTextBoxActive,
           let activePaneBoundaryColor = appearance.activePaneBoundaryColor,
           isSplit && isFocused && isVisibleInUI {
            ZStack {
                HStack(spacing: 0) {
                    activePaneBoundaryColor.frame(width: activeBoundaryLineWidth)
                    Spacer(minLength: 0)
                    activePaneBoundaryColor.frame(width: activeBoundaryLineWidth)
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    activePaneBoundaryColor.frame(height: activeBoundaryLineWidth)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var activeBoundaryLineWidth: CGFloat {
        CGFloat(PaneChromeSettings.activeBorderLineWidth)
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
            CmuxSystemSymbolImage(magnified: "pause.circle", pointSize: 34, weight: .regular)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(String(localized: "terminal.agentHibernation.title", defaultValue: "Agent hibernated"))
                    .cmuxFont(.headline)
                Text(state.agentDisplayName)
                    .cmuxFont(.subheadline)
                    .foregroundStyle(.secondary)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "terminal.agentHibernation.lastActivity", defaultValue: "Last activity %@"),
                        lastActivityText
                    )
                )
                .cmuxFont(.caption)
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

/// Shared appearance settings for panels
struct PanelAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let dividerNSColor: NSColor
    let dividerColor: Color
    let activePaneBoundaryNSColor: NSColor?
    let activePaneBoundaryColor: Color?
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
        let dividerColor = config.resolvedSplitDividerColor
        let activeBoundaryColor = PaneChromeSettings.activePaneBorderColorHex()
            .flatMap { NSColor(hex: $0) }
        return PanelAppearance(
            backgroundColor: backgroundColor,
            foregroundColor: cmuxReadableForegroundNSColor(
                preferred: config.foregroundColor,
                on: backgroundColor
            ),
            dividerNSColor: dividerColor,
            dividerColor: Color(nsColor: dividerColor),
            activePaneBoundaryNSColor: activeBoundaryColor,
            activePaneBoundaryColor: activeBoundaryColor.map { Color(nsColor: $0) },
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
