import Foundation

extension TerminalController {
    /// Interim `Any`-shaped twin of the package's `ControlCallResult`, kept
    /// while the command bodies still build Foundation payloads. Bodies
    /// migrate onto the typed DTO in the ControlCommandCoordinator stage.
    /// Extracted from `TerminalController.swift`, which sits at its
    /// file-length budget.
    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }
}
