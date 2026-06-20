/// The default-terminal registration coverage for this app bundle: how many of
/// the LaunchServices targets (the `ssh` URL scheme plus the shell-script and
/// unix-executable content types) currently route to this bundle.
///
/// Lifted byte-for-byte from AppDelegate's `DefaultTerminalRegistrationStatus`.
/// It is a pure `Sendable` value consumed by the default-terminal Settings/menu
/// UI to decide whether to offer "Make Default Terminal", and produced by
/// ``DefaultTerminalRegistrar/currentStatus(bundleURL:workspace:)``.
public struct DefaultTerminalRegistrationStatus: Equatable, Sendable {
    /// The number of LaunchServices targets currently routing to this bundle.
    public let matchedTargetCount: Int
    /// The total number of LaunchServices targets cmux registers for.
    public let targetCount: Int

    /// Creates a registration status.
    /// - Parameters:
    ///   - matchedTargetCount: The targets currently routing to this bundle.
    ///   - targetCount: The total targets cmux registers for.
    public init(matchedTargetCount: Int, targetCount: Int) {
        self.matchedTargetCount = matchedTargetCount
        self.targetCount = targetCount
    }

    /// Whether every registered target routes to this bundle.
    public var isDefault: Bool {
        matchedTargetCount == targetCount
    }
}
