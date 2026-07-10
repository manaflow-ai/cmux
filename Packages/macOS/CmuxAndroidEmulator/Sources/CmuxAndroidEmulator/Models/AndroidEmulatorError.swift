/// Structured Android tooling failures for the UI to localize.
public enum AndroidEmulatorError: Error, Sendable, Equatable {
    /// No Android SDK root could be found.
    case sdkNotFound

    /// The selected SDK root does not contain the emulator component.
    case emulatorMissing(sdkPath: String)

    /// The selected SDK root does not contain Android Debug Bridge.
    case adbMissing(sdkPath: String)

    /// A vendor command failed or timed out.
    case commandFailed(tool: String, detail: String)

    /// The requested AVD was not reported by the installed emulator.
    case avdNotFound(name: String)

    /// The requested Android Debug Bridge serial is not an emulator serial.
    case invalidEmulatorSerial(String)

    /// The vendor emulator process could not be launched.
    case launchFailed(detail: String)

    /// A spawned AVD did not become visible to Android Debug Bridge before the confirmation deadline.
    case launchNotConfirmed(name: String)

    /// A stopped emulator remained visible to Android Debug Bridge after the confirmation deadline.
    case stopNotConfirmed(serial: String)

    /// A reusable emulator serial now belongs to a different AVD than the selected row.
    case avdIdentityChanged(expected: String, actual: String)
}
