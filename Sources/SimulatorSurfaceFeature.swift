import CmuxSettings
import Foundation

/// The `simulator.beta.enabled` feature gate for the iOS Simulator surface.
///
/// Every entry point (the `cmux simulator` CLI namespace via its socket verbs,
/// and the workspace pane factory) funnels through ``isEnabled`` so the
/// feature refuses uniformly while the Settings → Beta Features toggle is off,
/// and no `simctl` process is ever spawned for a disabled feature.
enum SimulatorSurfaceFeature {
    /// Synchronous read of the feature flag, resolved through the settings
    /// catalog so id/default/decode stay single-sourced (same shape as
    /// `RemoteTmuxController.isEnabled`).
    nonisolated static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.simulatorSurface
        return Bool.decodeFromUserDefaults(
            UserDefaults.standard.object(forKey: key.userDefaultsKey)
        ) ?? key.defaultValue
    }

    /// The one guidance line shown when an entry point refuses because the
    /// flag is off (CLI error text; intentionally English like other CLI
    /// output).
    nonisolated static let disabledGuidance =
        "The simulator surface is disabled. Enable \"iOS Simulator Panes\" in Settings → Beta Features (simulator.beta.enabled)."
}
