import CmuxSettings
import Foundation

/// Adapts persisted app preferences to the shared title-bar policy.
struct WorkspaceTitlebarSettings: Equatable {
    private static let setting = AppCatalogSection().workspaceTitlebarVisibility
    static let showTitlebarKey = setting.userDefaultsKey
    static let defaultShowTitlebar = setting.defaultValue

    private let policy: WorkspaceTitlebarPolicy

    var showTitlebar: Bool { policy.showTitlebar }
    var isMinimalMode: Bool { policy.isMinimalMode }
    var isHidden: Bool { policy.isHidden }

    func tabBarLeadingInset(
        isSidebarVisible: Bool,
        isFullScreen: Bool,
        trafficLightInset: CGFloat,
        fullscreenControlsWidth: CGFloat
    ) -> CGFloat {
        policy.tabBarLeadingInset(
            isSidebarVisible: isSidebarVisible,
            isFullScreen: isFullScreen,
            trafficLightInset: trafficLightInset,
            fullscreenControlsWidth: fullscreenControlsWidth
        )
    }

    init(showTitlebar: Bool, isMinimalMode: Bool) {
        policy = WorkspaceTitlebarPolicy(showTitlebar: showTitlebar, isMinimalMode: isMinimalMode)
    }

    init(defaults: UserDefaults = .standard) {
        self.init(
            showTitlebar: UserDefaultsSettingsClient(defaults: defaults).value(for: Self.setting),
            isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
        )
    }
}
