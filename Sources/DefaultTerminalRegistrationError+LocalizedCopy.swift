import CmuxWindowing
import Foundation

// MARK: - Default-terminal registration failure copy (app-side localization)

extension DefaultTerminalRegistrationError {
    /// The user-facing message for this registration failure. `String(localized:)`
    /// must resolve in the app bundle (the `CmuxWindowing` error is plain data so
    /// the package never drops the Japanese translation), so the localized copy is
    /// produced here, app-side, from the typed case.
    var localizedFailureDescription: String {
        switch self {
        case .launchServicesRegistrationFailed:
            return String(
                localized: "error.defaultTerminal.registrationFailed",
                defaultValue: "cmux could not register as the default terminal app."
            )
        }
    }
}
