public import Foundation

/// A minimal, credential-free support snapshot that identifies one mobile run.
///
/// The snapshot includes only the identifiers and build metadata needed to
/// correlate a support request with authenticated Axiom and Sentry records. It
/// never includes access tokens, refresh tokens, terminal contents, or secrets.
public struct MobileDebugInformation: Equatable, Sendable {
    /// The authenticated Stack account id, when available.
    public let accountID: String?
    /// The anonymous analytics installation id, when available.
    public let installID: String?
    /// The vendor device identifier reported by the operating system, when available.
    public let deviceID: String?
    /// The app marketing version.
    public let appVersion: String?
    /// The app build number.
    public let buildNumber: String?
    /// The time at which the support snapshot was copied.
    public let reportedAt: Date

    /// Creates a support snapshot from already-resolved runtime values.
    public init(
        accountID: String? = nil,
        installID: String? = nil,
        deviceID: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        reportedAt: Date = Date()
    ) {
        self.accountID = accountID
        self.installID = installID
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.reportedAt = reportedAt
    }

    /// The plain-text report suitable for pasting into a support request.
    public var report: String {
        [
            ("Account ID", accountID),
            ("Install ID", installID),
            ("Device ID", deviceID),
            ("App Version", appVersion),
            ("Build Number", buildNumber),
        ]
        .map { "\($0.0): \($0.1 ?? "<unavailable>")" }
        .joined(separator: "\n")
        .appending("\nReported At (UTC): \(reportedAt.ISO8601Format(.iso8601.dateTimeSeparator(.standard)))")
    }
}
