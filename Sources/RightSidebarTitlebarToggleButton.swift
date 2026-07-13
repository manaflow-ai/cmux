import SwiftUI

/// The shared title-bar control for showing and hiding the right sidebar.
struct RightSidebarTitlebarToggleButton: View {
    let config: TitlebarControlsStyleConfig
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        TitlebarControlButton(
            config: config,
            foregroundColor: Color(nsColor: titlebarControlForegroundNSColor(opacity: 1)),
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
    }
}
