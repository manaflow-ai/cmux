import CmuxSettings
import Foundation

/// Resolves title-strip visibility without changing the pane tabs or Minimal Mode.
struct WorkspaceTitlebarSettings: Equatable {
    private static let setting = AppCatalogSection().workspaceTitlebarVisibility
    static let showTitlebarKey = setting.userDefaultsKey
    static let defaultShowTitlebar = setting.defaultValue

    let showTitlebar: Bool
    let isMinimalMode: Bool

    // Minimal Mode retains ownership of its compact chrome, but never overwrites
    // the independent preference restored when the user leaves Minimal Mode.
    var isHidden: Bool { isMinimalMode || !showTitlebar }

    func tabBarLeadingInset(
        isSidebarVisible: Bool,
        isFullScreen: Bool,
        trafficLightInset: CGFloat,
        fullscreenControlsWidth: CGFloat
    ) -> CGFloat {
        guard isHidden, !isSidebarVisible else { return 0 }
        if isFullScreen {
            // Keep standard-mode actions available beside the tabs in fullscreen.
            // Minimal Mode retains its existing sidebar-only controls.
            return isMinimalMode ? 0 : fullscreenControlsWidth + 16
        }
        return trafficLightInset
    }

    init(showTitlebar: Bool, isMinimalMode: Bool) {
        self.showTitlebar = showTitlebar
        self.isMinimalMode = isMinimalMode
    }

    init(defaults: UserDefaults = .standard) {
        self.init(
            showTitlebar: UserDefaultsSettingsClient(defaults: defaults).value(for: Self.setting),
            isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
        )
    }
}
