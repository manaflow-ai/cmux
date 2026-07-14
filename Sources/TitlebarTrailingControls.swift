import Foundation
import SwiftUI

/// The built-in trailing title-bar cluster shared by every main window.
struct TitlebarTrailingControls: View {
    @ObservedObject var fileExplorerState: FileExplorerState
    let onToggleRightSidebar: () -> Void
    @AppStorage(TitlebarControlsStyle.storageKey)
    private var styleRawValue = TitlebarControlsStyle.defaultRawValue
    @AppStorage(SidebarMatchTerminalBackgroundSettings.userDefaultsKey)
    private var sidebarMatchesTerminalBackground = false
    @AppStorage(AppearanceSettings.appearanceModeKey)
    private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @State private var appearanceRefreshTick = 0

    private var rightSidebarToggleForegroundColor: Color {
        if fileExplorerState.isVisible && !sidebarMatchesTerminalBackground {
            return .primary
        }
        return Color(nsColor: titlebarControlForegroundNSColor(opacity: 1))
    }

    var body: some View {
        let _ = appearanceRefreshTick
        HStack(spacing: 4) {
            ProBadgeView()
            MobileConnectTitlebarButton()
            RightSidebarTitlebarToggleButton(
                config: TitlebarControlsStyle.stored(rawValue: styleRawValue).config,
                isVisible: fileExplorerState.isVisible,
                foregroundColor: rightSidebarToggleForegroundColor,
                action: onToggleRightSidebar
            )
        }
        .padding(.trailing, 8)
        .cmuxAppearanceColorScheme(appearanceMode)
        .task {
            for await _ in NotificationCenter.default.notifications(named: .ghosttyConfigDidReload) {
                guard !Task.isCancelled else { return }
                appearanceRefreshTick &+= 1
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .ghosttyDefaultBackgroundDidChange) {
                guard !Task.isCancelled else { return }
                appearanceRefreshTick &+= 1
            }
        }
    }
}
