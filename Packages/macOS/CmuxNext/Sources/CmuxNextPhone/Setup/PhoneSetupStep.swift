/// The one thing a Mac still needs before the phone tab can show an iPhone
/// simulator, in the order a new user meets them. ``ready`` means nothing is
/// missing. The raw values are what `cmux phone list` answers as `setup`.
public enum PhoneSetupStep: String, Sendable, Hashable, Codable, CaseIterable {
    /// No Xcode (maybe only the command line tools, which have no simulators).
    case installXcode = "install-xcode"
    /// Xcode is installed but never opened: its license is not accepted or
    /// its first-launch components are not installed. Opening Xcode once fixes both.
    case finishXcode = "finish-xcode"
    /// Xcode works but has no iOS simulator runtime (Xcode 15 and later download it separately).
    case downloadIOS = "download-ios"
    /// The runtime is there but there is no iPhone or iPad simulator to show.
    case createIPhone = "create-iphone"
    /// Everything is in place.
    case ready

    /// The steps the setup screen lists, in order (``ready`` is not a step).
    public static let checklist: [PhoneSetupStep] = [.installXcode, .finishXcode, .downloadIOS, .createIPhone]

    /// Whether this step comes before `other` (so it is already done when `other` is the current step).
    public func isBefore(_ other: PhoneSetupStep) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: self) ?? 0) < (order.firstIndex(of: other) ?? 0)
    }
}
