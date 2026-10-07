import CmuxNextDesign

extension ModuleResourceBundle {
    /// This module's string table (Localizable.xcstrings). Use it instead of
    /// `Bundle.module`, which traps if the app's folder is deleted.
    nonisolated static let settings = ModuleResourceBundle(
        cmuxNextTarget: "CmuxNextSettings",
        anchor: SettingsController.self
    )
}
