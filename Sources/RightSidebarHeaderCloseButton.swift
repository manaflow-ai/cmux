import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Closes the right sidebar from its header while presenting the configured shortcut hint.
struct RightSidebarHeaderCloseButton: View {
    let action: () -> Void

    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var shortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    private let shortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintX
    private let shortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintY

    private func startShortcutHintMonitorIfNeeded() {
        if showModifierHoldHints {
            shortcutHintMonitor.start()
        } else {
            shortcutHintMonitor.stop()
        }
    }

    var body: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let showsShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: shortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )

        ZStack {
            Button(action: action) {
                HeaderChromeIconStyle.symbol("xmark")
            }
            .buttonStyle(
                RightSidebarHeaderIconButtonStyle(
                    iconGeometryKeyPrefix: "rightSidebarHeaderCloseIcon"
                )
            )
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: "rightSidebarHeaderClose",
                isVisible: true
            )
            .safeHelp(
                KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                    String(
                        localized: "rightSidebar.toggle.tooltip",
                        defaultValue: "Toggle right sidebar"
                    )
                )
            )
            .accessibilityLabel(
                String(
                    localized: "rightSidebar.close.accessibilityLabel",
                    defaultValue: "Close Right Sidebar"
                )
            )
            .accessibilityIdentifier("RightSidebar.closeButton")
        }
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                shortcutHintMonitor.setHostWindow(showModifierHoldHints ? window : nil)
            }
            .frame(width: 0, height: 0)
        )
        .overlay(alignment: .top) {
            if showsShortcutHint {
                ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(
                        x: CGFloat(ShortcutHintDebugSettings.clamped(shortcutHintXOffset)),
                        y: CGFloat(ShortcutHintDebugSettings.clamped(shortcutHintYOffset))
                    )
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarCloseShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .rightSidebarHeaderControlAlignment()
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .titlebarInteractiveControl()
        .onAppear {
            startShortcutHintMonitorIfNeeded()
        }
        .onDisappear {
            shortcutHintMonitor.stop()
        }
        .onChange(of: showModifierHoldHints) { _, _ in
            startShortcutHintMonitorIfNeeded()
        }
    }
}
