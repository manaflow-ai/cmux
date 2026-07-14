import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The built-in title-bar control for showing the hidden right sidebar.
struct RightSidebarTitlebarToggleButton: View {
    let foregroundColor: Color
    let action: () -> Void
    @AppStorage(TitlebarControlsStyle.storageKey)
    private var styleRawValue = TitlebarControlsStyle.defaultRawValue
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let config = TitlebarControlsStyle.stored(rawValue: styleRawValue).config
        TitlebarControlButton(
            config: config,
            foregroundColor: foregroundColor,
            accessibilityIdentifier: "titlebarControl.toggleRightSidebar",
            accessibilityLabel: String(
                localized: "shortcut.toggleRightSidebar.label",
                defaultValue: "Toggle Right Sidebar"
            ),
            action: action
        ) {
            TitlebarSidebarGlyph(edge: .trailing, iconSize: config.iconSize)
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
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize + 12,
            height: WindowChromeMetrics.appTitlebarHeight
        )
        .overlay(alignment: .leading) {
            WindowChromeBorder(
                orientation: .vertical,
                ignoresSafeArea: false,
                refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
            )
            .allowsHitTesting(false)
        }
    }
}
