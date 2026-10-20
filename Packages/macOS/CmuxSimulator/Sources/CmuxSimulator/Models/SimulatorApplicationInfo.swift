/// Metadata for the frontmost application on a simulated device.
public struct SimulatorApplicationInfo: Codable, Equatable, Sendable {
    /// The application's bundle identifier.
    public let bundleIdentifier: String
    /// The running process identifier when available.
    public let processIdentifier: Int32?
    /// The application display name when available.
    public let name: String?
    /// The short version string when available.
    public let version: String?
    /// The bundle build number when available.
    public let build: String?
    /// The minimum supported OS version when available.
    public let minimumOSVersion: String?
    /// The executable declared by the application bundle.
    public let executable: String?
    /// The absolute path to the application bundle in the Simulator data directory.
    public let bundlePath: String?
    /// Whether the installed bundle appears to contain React Native.
    public let isReactNative: Bool

    /// Creates an application snapshot.
    public init(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        name: String?,
        version: String?,
        build: String?,
        minimumOSVersion: String?,
        isReactNative: Bool,
        executable: String? = nil,
        bundlePath: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.name = name
        self.version = version
        self.build = build
        self.minimumOSVersion = minimumOSVersion
        self.isReactNative = isReactNative
        self.executable = executable
        self.bundlePath = bundlePath
    }
}
