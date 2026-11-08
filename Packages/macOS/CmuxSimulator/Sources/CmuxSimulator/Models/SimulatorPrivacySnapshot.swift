/// A correlated permission-status snapshot read inside the isolated worker.
public struct SimulatorPrivacySnapshot: Codable, Equatable, Sendable {
    /// The CoreSimulator device identifier.
    public let deviceID: String
    /// The application bundle identifier, or `nil` for runtime-wide status.
    public let bundleIdentifier: String?
    /// Effective authorization keyed by the public tools permission catalog.
    public let authorizations: [SimulatorPrivacyService: SimulatorPrivacyAuthorization]
    /// Per-application values for a runtime-wide readback.
    public let applications: [SimulatorPrivacyApplicationSnapshot]
    /// Whether a runtime-wide readback omitted applications at its fixed limit.
    public let isTruncated: Bool

    /// Creates a permission snapshot.
    /// - Parameters:
    ///   - deviceID: The CoreSimulator device identifier.
    ///   - bundleIdentifier: Optional application bundle identifier.
    ///   - authorizations: Effective values by permission.
    ///   - applications: Bounded per-application values for a runtime-wide readback.
    ///   - isTruncated: Whether more applications existed than the fixed output limit.
    public init(
        deviceID: String,
        bundleIdentifier: String?,
        authorizations: [SimulatorPrivacyService: SimulatorPrivacyAuthorization],
        applications: [SimulatorPrivacyApplicationSnapshot] = [],
        isTruncated: Bool = false
    ) {
        self.deviceID = deviceID
        self.bundleIdentifier = bundleIdentifier
        self.authorizations = authorizations
        self.applications = applications
        self.isTruncated = isTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case bundleIdentifier
        case authorizations
        case applications
        case isTruncated
    }

    /// Decodes snapshots from current or older bundled workers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        authorizations = try container.decode(
            [SimulatorPrivacyService: SimulatorPrivacyAuthorization].self,
            forKey: .authorizations
        )
        applications = try container.decodeIfPresent(
            [SimulatorPrivacyApplicationSnapshot].self,
            forKey: .applications
        ) ?? []
        isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    }
}
