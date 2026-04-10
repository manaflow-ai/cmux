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

    // [TextBox]
    @AppStorage(TextBoxInputSettings.enabledKey) private var textBoxEnabled = TextBoxInputSettings.defaultEnabled
    @AppStorage(TextBoxInputSettings.enterToSendKey) private var enterToSend = TextBoxInputSettings.defaultEnterToSend
    @AppStorage(TextBoxInputSettings.shortcutBehaviorKey) private var shortcutBehavior = TextBoxInputSettings.defaultShortcutBehavior.rawValue
    /// Whether the TextBox is visible. Requires both the global Enabled setting
    /// AND the per-panel `isTextBoxActive` flag. When Enabled is toggled on,
    /// `onChange` below forces `isTextBoxActive = true` so that TextBox always
    /// appears — even if the user had previously hidden it via the keyboard
    /// shortcut. This is intentional: Enabled on = TextBox visible.
    private var showTextBox: Bool {
        textBoxEnabled && panel.isTextBoxActive
    }

    var body: some View {
        let config = GhosttyConfig.load()

        // [TextBox] Apply background-opacity so TextBox matches the terminal
        let runtimeBg = GhosttyApp.shared.defaultBackgroundColor
            .withAlphaComponent(GhosttyApp.shared.defaultBackgroundOpacity)
        // [TextBox] Use runtime-resolved foreground to match terminal (not static parser)
        let runtimeFg = GhosttyApp.shared.defaultForegroundColor
        // [TextBox] Use terminal font size for consistent appearance
        let font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)

        // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
        // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
        VStack(spacing: 0) {
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

            // [TextBox] Show inline text input below terminal when enabled
            if showTextBox {
                TextBoxInputContainer(
                    text: $panel.textBoxContent,
                    enterToSend: enterToSend,
                    surface: panel.surface,
                    terminalBackgroundColor: runtimeBg,
                    terminalForegroundColor: runtimeFg,
                    terminalFont: font,
                    terminalTitle: panel.title,
                    onInputTextViewCreated: { panel.inputTextView = $0 }
                )
            }
        }

        // [TextBox] Force-show TextBox when the setting is toggled on, even if the
        // user previously hid it via Cmd+Opt+T. "Enabled = always visible" is the
        // expected behavior so the setting toggle feels deterministic.
        .onChange(of: textBoxEnabled) { enabled in
            if enabled && !panel.isTextBoxActive {
                panel.isTextBoxActive = true
            }
        }
        // [TextBox] Auto-show TextBox when switching to Toggle Focus mode,
        // since that mode assumes TextBox is always visible.
        .onChange(of: shortcutBehavior) { newValue in
            if newValue == TextBoxShortcutBehavior.toggleFocus.rawValue && !panel.isTextBoxActive {
                panel.isTextBoxActive = true
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
