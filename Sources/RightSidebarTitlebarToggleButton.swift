import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The built-in title-bar control for showing and hiding the right sidebar.
struct RightSidebarTitlebarToggleButton: View {
    let isVisible: Bool
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
            action: action,
            isSelected: isVisible
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
        .accessibilityAddTraits(isVisible ? .isSelected : [])
    }
}

/// Keeps the open-sidebar header clear for the window-owned toggle overlay.
struct RightSidebarTitlebarToggleReservation: View {
    @AppStorage(TitlebarControlsStyle.storageKey)
    private var styleRawValue = TitlebarControlsStyle.defaultRawValue

    var body: some View {
        let config = TitlebarControlsStyle.stored(rawValue: styleRawValue).config
        Color.clear
            .frame(width: config.buttonSize, height: config.buttonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
