/// What the setup screen is doing right now.
public enum PhoneSetupActivity: Sendable, Hashable {
    /// Asking this Mac what is installed.
    case checking
    /// Downloading and installing the iOS runtime.
    case downloading(PhoneSetupProgress)
    /// Creating and starting an iPhone simulator.
    case creating
}
