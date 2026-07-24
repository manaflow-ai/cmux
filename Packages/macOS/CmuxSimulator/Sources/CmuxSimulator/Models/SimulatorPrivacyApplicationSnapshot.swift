/// One application's effective permission values in a runtime-wide readback.
public struct SimulatorPrivacyApplicationSnapshot: Codable, Equatable, Sendable {
    /// The application bundle identifier.
    public let bundleIdentifier: String
    /// Effective authorization keyed by the public tools permission catalog.
    public let authorizations: [SimulatorPrivacyService: SimulatorPrivacyAuthorization]

    /// Creates one application permission snapshot.
    public init(
        bundleIdentifier: String,
        authorizations: [SimulatorPrivacyService: SimulatorPrivacyAuthorization]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.authorizations = authorizations
    }
}
