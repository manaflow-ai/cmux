import AppKit
import SwiftUI

/// Hosts the per-window controls anchored to the trailing edge of the title bar.
final class TitlebarTrailingAccessoryViewController: NSTitlebarAccessoryViewController {
    let fileExplorerState: FileExplorerState

    init(fileExplorerState: FileExplorerState, onToggleRightSidebar: @escaping () -> Void) {
        self.fileExplorerState = fileExplorerState
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right

        let hosting = NSHostingView(
            rootView: TitlebarTrailingControls(
                fileExplorerState: fileExplorerState,
                onToggleRightSidebar: onToggleRightSidebar
            )
        )
        hosting.setContentHuggingPriority(.required, for: .horizontal)
        view = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The built-in trailing title-bar cluster shared by every main window.
private struct TitlebarTrailingControls: View {
    @ObservedObject var fileExplorerState: FileExplorerState
    let onToggleRightSidebar: () -> Void
    @AppStorage(TitlebarControlsStyle.storageKey)
    private var styleRawValue = TitlebarControlsStyle.defaultRawValue
    @AppStorage(SidebarMatchTerminalBackgroundSettings.userDefaultsKey)
    private var sidebarMatchesTerminalBackground = false
    @AppStorage(AppearanceSettings.appearanceModeKey)
    private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    private var rightSidebarToggleForegroundColor: Color {
        if fileExplorerState.isVisible && !sidebarMatchesTerminalBackground {
            return .primary
        }
        return Color(nsColor: titlebarControlForegroundNSColor(opacity: 1))
    }

    var body: some View {
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
    }
}
