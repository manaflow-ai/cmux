import CmuxNextDesign

extension ModuleResourceBundle {
    /// This module's string table (Resources/Localizable.xcstrings). Use it
    /// instead of `Bundle.module`, which traps if the app's folder is deleted.
    nonisolated static let terminal = ModuleResourceBundle(
        cmuxNextTarget: "CmuxNextTerminal",
        anchor: TerminalStatusBanner.self
    )
}
