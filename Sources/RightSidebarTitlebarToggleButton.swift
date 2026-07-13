import SwiftUI

/// The shared title-bar control for showing and hiding the right sidebar.
struct RightSidebarTitlebarToggleButton: View {
    let config: TitlebarControlsStyleConfig
    let isVisible: Bool
    let foregroundColor: Color
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
        TitlebarControlButton(
            config: config,
            foregroundColor: foregroundColor,
            accessibilityIdentifier: "titlebarControl.toggleRightSidebar",
            accessibilityLabel: String(
                localized: "shortcut.toggleRightSidebar.label",
                defaultValue: "Toggle Right Sidebar"
            ),
            action: action,
            isSelected: isVisible
        ) {
            CmuxSystemSymbolImage(
                systemName: "sidebar.right",
                pointSize: config.iconSize,
                weight: HeaderChromeIconStyle.weight
            )
            .frame(
                width: HeaderChromeIconStyle.iconFrameSize(forIconSize: config.iconSize),
                height: HeaderChromeIconStyle.iconFrameSize(forIconSize: config.iconSize)
            )
            .background(
                TitlebarChromeGeometryReporter(
                    keyPrefix: "titlebarControl_toggleRightSidebarIcon"
                )
            )
        }
        .safeHelp(
            KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                String(
                    localized: "rightSidebar.toggle.tooltip",
                    defaultValue: "Toggle right sidebar"
                )
            )
        )
        .accessibilityAddTraits(isVisible ? .isSelected : [])
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
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
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
