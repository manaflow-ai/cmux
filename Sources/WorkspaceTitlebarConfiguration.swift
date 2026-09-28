import SwiftUI

/// Observes chrome preferences at the small layout leaves, not the workspace body.
@propertyWrapper
struct WorkspaceTitlebarConfiguration: DynamicProperty {
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var presentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(WorkspaceTitlebarSettings.showTitlebarKey)
    private var showTitlebar = WorkspaceTitlebarSettings.defaultShowTitlebar

    var wrappedValue: WorkspaceTitlebarSettings {
        WorkspaceTitlebarSettings(
            showTitlebar: showTitlebar,
            isMinimalMode: WorkspacePresentationModeSettings.mode(for: presentationMode) == .minimal
        )
    }
}
