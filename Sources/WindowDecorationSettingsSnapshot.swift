import Foundation

/// Immutable settings consumed by window-decoration event paths.
struct WindowDecorationSettingsSnapshot: Equatable, Sendable {
    let presentationMode: WorkspacePresentationModeSettings.Mode
    let titlebarDebug: MinimalModeTitlebarDebugSnapshot
    let controlsStyle: TitlebarControlsStyle

    static let bootstrap = WindowDecorationSettingsSnapshot(
        presentationMode: .standard,
        titlebarDebug: MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        ),
        controlsStyle: .defaultStyle
    )

    static func load(defaults: UserDefaults = .standard) -> WindowDecorationSettingsSnapshot {
        WindowDecorationSettingsSnapshot(
            presentationMode: WorkspacePresentationModeSettings.mode(defaults: defaults),
            titlebarDebug: MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults),
            controlsStyle: TitlebarControlsStyle.stored(in: defaults)
        )
    }

    func replacingPresentationMode(
        _ presentationMode: WorkspacePresentationModeSettings.Mode
    ) -> WindowDecorationSettingsSnapshot {
        WindowDecorationSettingsSnapshot(
            presentationMode: presentationMode,
            titlebarDebug: titlebarDebug,
            controlsStyle: controlsStyle
        )
    }
}
