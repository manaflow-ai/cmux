/// Non-fatal limitation encountered while reading Android emulator state.
public enum AndroidEmulatorWarning: Sendable, Equatable {
    /// The SDK can launch AVDs, but Android Debug Bridge is not installed.
    case adbMissing

    /// Android Debug Bridge exists but did not return device state.
    case adbQueryFailed(detail: String)
}
