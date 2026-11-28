public import Foundation

/// A credential-free support snapshot that identifies one mobile run.
///
/// The snapshot includes only the identifiers and build metadata needed to
/// correlate a support request with authenticated Axiom and Sentry records. It
/// never includes email, host names, access tokens, refresh tokens, terminal
/// contents, or secrets.
public struct MobileDebugInformation: Equatable, Sendable {
    /// The authenticated Stack account id, when available.
    public let accountID: String?
    /// The anonymous analytics installation id, when available.
    public let installID: String?
    /// The vendor device identifier reported by the operating system, when available.
    public let deviceID: String?
    /// The selected Stack team id, when available.
    public let teamID: String?
    /// The app bundle identifier used by telemetry to identify the build lane.
    public let bundleID: String?
    /// The coarse app channel used by telemetry, such as dev or production.
    public let appChannel: String?
    /// The app marketing version.
    public let appVersion: String?
    /// The app build number.
    public let buildNumber: String?
    /// The iOS version reported by the operating system.
    public let osVersion: String?
    /// The device model reported by UIKit.
    public let deviceModel: String?
    /// The current mobile-to-Mac connection state, when available.
    public let connectionState: String?
    /// The transport carrying the current connection, when available.
    public let transport: String?
    /// The time at which the support snapshot was copied.
    public let reportedAt: Date

    /// Creates a support snapshot from already-resolved runtime values.
    public init(
        accountID: String? = nil,
        installID: String? = nil,
        deviceID: String? = nil,
        teamID: String? = nil,
        bundleID: String? = nil,
        appChannel: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        connectionState: String? = nil,
        transport: String? = nil,
        reportedAt: Date = Date()
    ) {
        self.accountID = accountID
        self.installID = installID
        self.deviceID = deviceID
        self.teamID = teamID
        self.bundleID = bundleID
        self.appChannel = appChannel
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.connectionState = connectionState
        self.transport = transport
        self.reportedAt = reportedAt
    }

    /// The plain-text report suitable for pasting into a support request.
    public var report: String {
        [
            ("Account ID", accountID),
            ("Install ID", installID),
            ("Device ID", deviceID),
            ("Team ID", teamID),
            ("Bundle ID", bundleID),
            ("App Channel", appChannel),
            ("App Version", appVersion),
            ("Build Number", buildNumber),
            ("iOS Version", osVersion),
            ("Device Model", deviceModel),
            ("Connection State", connectionState),
            ("Transport", transport),
        ]
        .map { "\($0.0): \($0.1 ?? "<unavailable>")" }
        .joined(separator: "\n")
        .appending("\nReported At (UTC): \(reportedAt.ISO8601Format(.iso8601.dateTimeSeparator(.standard)))")
    }
}
