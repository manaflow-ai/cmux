/// What `install.register` declares for this install (backend
/// `InstallRegister`): its kind, labels, platform and an optional narrowing
/// of the kind's default grant. The iPhone and the Mac app share the client;
/// only this differs.
public struct InstallRegistration: Hashable, Sendable {
    /// `ios`, `mac`, … (backend `InstallKind`; server kinds are refused).
    public var kind: String
    /// The app's name for the install ("cmux iOS").
    public var name: String
    /// `ios`, `macos`, … (backend `Platform`).
    public var platform: String
    /// Used when the device name is empty.
    public var fallbackDeviceName: String
    /// Narrows the kind's default grant; nil takes the owner's default.
    public var opClasses: [String]?

    public init(kind: String, name: String, platform: String, fallbackDeviceName: String, opClasses: [String]?) {
        self.kind = kind
        self.name = name
        self.platform = platform
        self.fallbackDeviceName = fallbackDeviceName
        self.opClasses = opClasses
    }

    /// The iPhone app: `read`, `mutate-own` and `cloud-link` only (L14-1: a
    /// stolen phone token gets no `execute`).
    public static let iOS = InstallRegistration(kind: "ios", name: "cmux iOS", platform: "ios", fallbackDeviceName: "iPhone",
                                                opClasses: InstallAuthClient.grantClasses)

    /// The Mac app: the owner's `mac` default grant. Its install enrolls the
    /// Mac as a host (`host.enroll`, `mutate-shared`) and signs its link keys.
    public static let macOS = InstallRegistration(kind: "mac", name: "cmux", platform: "macos", fallbackDeviceName: "Mac",
                                                  opClasses: nil)
}
