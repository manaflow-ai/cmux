import Foundation

/// A stable, credential-free support snapshot that identifies one mobile run.
///
/// The snapshot intentionally includes account and installation identifiers so
/// support can correlate a report with authenticated Axiom spans. It never
/// includes access tokens, refresh tokens, terminal contents, or secrets.
public struct MobileDebugInformation: Equatable, Sendable {
    /// The device identifier reported by the operating system, when available.
    public let deviceID: String?
    /// The signed-in account email, when available.
    public let email: String?
    /// The authenticated Hexclave/Stack user id, when available.
    public let hexclaveAuthID: String?
    /// The selected Stack team id, when available.
    public let teamID: String?
    /// The app bundle identifier.
    public let bundleID: String?
    /// The app marketing version.
    public let appVersion: String?
    /// The app build number.
    public let buildNumber: String?
    /// The iOS version.
    public let osVersion: String?
    /// The device model reported by UIKit.
    public let deviceModel: String?
    /// The anonymous analytics installation id used to correlate product events.
    public let analyticsClientID: String?
    /// The currently selected Mac host, when available.
    public let connectedHost: String?
    /// The current connection state, when available.
    public let connectionState: String?
    /// The transport carrying the current connection, when available.
    public let transport: String?

    /// Creates a support snapshot from already-resolved runtime values.
    public init(
        deviceID: String? = nil,
        email: String? = nil,
        hexclaveAuthID: String? = nil,
        teamID: String? = nil,
        bundleID: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        analyticsClientID: String? = nil,
        connectedHost: String? = nil,
        connectionState: String? = nil,
        transport: String? = nil
    ) {
        self.deviceID = deviceID
        self.email = email
        self.hexclaveAuthID = hexclaveAuthID
        self.teamID = teamID
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.analyticsClientID = analyticsClientID
        self.connectedHost = connectedHost
        self.connectionState = connectionState
        self.transport = transport
    }

    /// The plain-text report suitable for pasting into a support request.
    public var report: String {
        [
            ("Device ID", deviceID),
            ("Email", email),
            ("Hexclave Auth ID", hexclaveAuthID),
            ("Team ID", teamID),
            ("Bundle ID", bundleID),
            ("App Version", appVersion),
            ("Build Number", buildNumber),
            ("iOS Version", osVersion),
            ("Device Model", deviceModel),
            ("Analytics Client ID", analyticsClientID),
            ("Connected Host", connectedHost),
            ("Connection State", connectionState),
            ("Transport", transport),
        ]
        .map { "\($0.0): \($0.1 ?? "<unavailable>")" }
        .joined(separator: "\n")
    }
}
