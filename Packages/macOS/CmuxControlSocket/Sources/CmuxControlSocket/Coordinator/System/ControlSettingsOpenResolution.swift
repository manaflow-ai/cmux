/// The outcome of `settings.open` (the legacy `v2SettingsOpen` body): the app
/// validates the target against its `SettingsNavigationTarget` enum and
/// presents the window before replying, so `opened` means a window actually
/// materialized (https://github.com/manaflow-ai/cmux/issues/7775).
public enum ControlSettingsOpenResolution: Sendable, Equatable {
    /// The `target` param did not name a known settings pane.
    case invalidTarget
    /// The settings window was presented (or ordered front under a hidden
    /// app). Carries the resolved target raw value (`"general"` when no
    /// target was given).
    case opened(target: String)
    /// The app could not make a settings window visible. `message` carries
    /// the diagnostic reason from the window presenter.
    case failed(message: String)
}
