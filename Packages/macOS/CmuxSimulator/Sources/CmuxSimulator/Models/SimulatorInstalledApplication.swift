/// Metadata returned by `simctl listapps` for one installed application.
public struct SimulatorInstalledApplication: Equatable, Identifiable, Sendable {
    /// The application bundle identifier.
    public let id: String
    /// The bundle's internal name.
    public let name: String
    /// The user-facing display name.
    public let displayName: String
    /// The executable filename.
    public let executableName: String
    /// The installed application-bundle path.
    public let path: String
    /// CoreSimulator's application type, such as `User` or `System`.
    public let applicationType: String

    /// Creates installed-application metadata.
    public init(
        id: String,
        name: String,
        displayName: String,
        executableName: String,
        path: String,
        applicationType: String
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.executableName = executableName
        self.path = path
        self.applicationType = applicationType
    }
}
