import Foundation

/// The optional attribute bag attached to a mobile analytics event.
///
/// Every property is optional; only the relevant ones are set per event. Use
/// ``withDefaults(platform:bundleId:)`` to fill in platform and bundle id at send time.
public struct MobileAnalyticsProperties: Encodable, Equatable, Sendable {
    /// The team identifier the event is attributed to.
    public let teamId: String?

    /// Whether the team is personal or shared.
    public let teamKind: MobileAnalyticsTeamKind?

    /// The user identifier the event is attributed to.
    public let userId: String?

    /// The machine identifier the event relates to.
    public let machineId: String?

    /// The workspace identifier the event relates to.
    public let workspaceId: String?

    /// The client platform, for example `ios`.
    public let platform: String?

    /// The app bundle identifier.
    public let bundleId: String?

    /// A free-form source label for the event.
    public let source: String?

    /// A free-form result label for the event.
    public let result: String?

    /// An error code when the event reports a failure.
    public let errorCode: String?

    /// A measured latency in milliseconds.
    public let latencyMs: Int?

    /// The age of a cached value in milliseconds.
    public let cacheAgeMs: Int?

    /// A count of workspaces relevant to the event.
    public let workspaceCount: Int?

    /// A count of unread items relevant to the event.
    public let unreadCount: Int?

    /// Creates an analytics property bag.
    ///
    /// - Parameters:
    ///   - teamId: The team identifier the event is attributed to.
    ///   - teamKind: Whether the team is personal or shared.
    ///   - userId: The user identifier the event is attributed to.
    ///   - machineId: The machine identifier the event relates to.
    ///   - workspaceId: The workspace identifier the event relates to.
    ///   - platform: The client platform, for example `ios`.
    ///   - bundleId: The app bundle identifier.
    ///   - source: A free-form source label for the event.
    ///   - result: A free-form result label for the event.
    ///   - errorCode: An error code when the event reports a failure.
    ///   - latencyMs: A measured latency in milliseconds.
    ///   - cacheAgeMs: The age of a cached value in milliseconds.
    ///   - workspaceCount: A count of workspaces relevant to the event.
    ///   - unreadCount: A count of unread items relevant to the event.
    public init(
        teamId: String? = nil,
        teamKind: MobileAnalyticsTeamKind? = nil,
        userId: String? = nil,
        machineId: String? = nil,
        workspaceId: String? = nil,
        platform: String? = nil,
        bundleId: String? = nil,
        source: String? = nil,
        result: String? = nil,
        errorCode: String? = nil,
        latencyMs: Int? = nil,
        cacheAgeMs: Int? = nil,
        workspaceCount: Int? = nil,
        unreadCount: Int? = nil
    ) {
        self.teamId = teamId
        self.teamKind = teamKind
        self.userId = userId
        self.machineId = machineId
        self.workspaceId = workspaceId
        self.platform = platform
        self.bundleId = bundleId
        self.source = source
        self.result = result
        self.errorCode = errorCode
        self.latencyMs = latencyMs
        self.cacheAgeMs = cacheAgeMs
        self.workspaceCount = workspaceCount
        self.unreadCount = unreadCount
    }

    /// Returns a copy with `platform` and `bundleId` filled in when not already set.
    ///
    /// - Parameters:
    ///   - platform: The platform to use when this value has no platform set.
    ///   - bundleId: The bundle id to use when this value has no bundle id set.
    /// - Returns: A copy with platform and bundle id defaulted.
    public func withDefaults(platform: String, bundleId: String?) -> Self {
        Self(
            teamId: teamId,
            teamKind: teamKind,
            userId: userId,
            machineId: machineId,
            workspaceId: workspaceId,
            platform: self.platform ?? platform,
            bundleId: self.bundleId ?? bundleId,
            source: source,
            result: result,
            errorCode: errorCode,
            latencyMs: latencyMs,
            cacheAgeMs: cacheAgeMs,
            workspaceCount: workspaceCount,
            unreadCount: unreadCount
        )
    }
}
