/// Metadata for one WebKit target exposed by a simulated application.
public struct ControlSimulatorWebInspectorTargetSnapshot: Sendable, Equatable {
    /// The stable target identifier used by attach operations.
    public let id: String
    /// WebKit's application identifier for the target owner.
    public let applicationIdentifier: String
    /// WebKit's numeric page identifier.
    public let pageIdentifier: UInt64
    /// The target's current page title.
    public let title: String
    /// The target's current URL.
    public let url: String
    /// The WebKit target type.
    public let type: String
    /// The display name of the owning application.
    public let applicationName: String
    /// The bundle identifier of the owning application, when available.
    public let bundleIdentifier: String?
    /// Whether another inspector session is using the target.
    public let isInUse: Bool

    /// Creates an immutable Web Inspector target snapshot.
    public init(
        id: String,
        applicationIdentifier: String,
        pageIdentifier: UInt64,
        title: String,
        url: String,
        type: String,
        applicationName: String,
        bundleIdentifier: String?,
        isInUse: Bool
    ) {
        self.id = id
        self.applicationIdentifier = applicationIdentifier
        self.pageIdentifier = pageIdentifier
        self.title = title
        self.url = url
        self.type = type
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.isInUse = isInUse
    }
}
