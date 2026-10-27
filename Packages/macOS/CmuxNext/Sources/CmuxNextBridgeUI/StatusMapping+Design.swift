public import CmuxNextBridge
import CmuxNextDesign

extension StatusMapping {
    /// The app's mapping: the shared turn and seen stores, with the settings `DesignSettings` holds.
    public static let shared = StatusMapping(settings: .design)
}

extension StatusMapping.Settings {
    /// `DesignSettings.shared`'s `statusBehavior` and `statusIndicator`, read on each call, so a
    /// settings change applies to the next mapping.
    public static let design = StatusMapping.Settings(behavior: { DesignSettings.shared.statusBehavior },
                                                      indicator: { DesignSettings.shared.statusIndicator })
}
