/// A failure raised while registering this app bundle as the default terminal
/// through LaunchServices.
///
/// Lifted from AppDelegate's `DefaultTerminalRegistrationError`. The localized
/// `errorDescription` stayed in the app target: `String(localized:)` resolved
/// inside this package binds to the package bundle (which lacks the catalog
/// keys) and silently drops every non-English translation, so the user-facing
/// message is produced at the app-side presentation site from this typed case.
/// This type carries only the failure data.
public enum DefaultTerminalRegistrationError: Error, Equatable, Sendable {
    /// The `LSRegisterURL` call failed with the given OSStatus.
    case launchServicesRegistrationFailed(Int32)
}
