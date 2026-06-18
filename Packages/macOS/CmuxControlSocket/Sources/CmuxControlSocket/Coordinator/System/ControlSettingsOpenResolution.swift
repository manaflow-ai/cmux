/// The outcome of `settings.open` (the legacy `v2SettingsOpen` body): the app
/// validates the target against its `SettingsNavigationTarget` enum and
/// schedules the window presentation.
public enum ControlSettingsOpenResolution: Sendable, Equatable {
    /// The `target` param did not name a known settings pane.
    case invalidTarget
    /// The settings window presentation was scheduled. Carries the resolved
    /// target raw value (`"general"` when no target was given).
    case opened(target: String)
}
