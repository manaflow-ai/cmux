public import Foundation

/// Whether this launch sends crash reports, and how they are labeled.
///
/// The consent rule is the main app's (`TelemetrySettings` +
/// `MacSentryStartupPolicy`): the user's `sendAnonymousTelemetry` choice
/// (on until the user turns it off), the `DisableTelemetry` managed policy
/// winning over it, read once per launch, never inside a test process, and
/// only for a build that identifies as cmux (forks keep the public source
/// and its DSN; their reports must not reach us).
///
/// The labels keep cmux-next reports apart from the main app's, which
/// shares the Sentry project: a `-next` environment per channel (`dev` for
/// DEV builds and tags), a `cmux-next@<version>+<build>` release, and an
/// `app: cmux-next` tag (``CrashEventLabels``).
public nonisolated struct CrashReportingPolicy: Sendable, Equatable {
    /// The build channel, from the bundle identifier.
    public enum Channel: String, Sendable, Equatable {
        case dev
        case nightly
        case rc
        case release

        /// The Sentry environment: never the main app's `development` or
        /// `production`.
        public var environment: String {
            switch self {
            case .dev: "dev"
            case .nightly: "nightly-next"
            case .rc: "rc-next"
            case .release: "release-next"
            }
        }
    }

    /// The `UserDefaults` key of the anonymous telemetry choice, shared with
    /// the main app and the iOS app (one choice per bundle domain).
    public static let telemetryKey = "sendAnonymousTelemetry"
    /// The managed policy key that turns telemetry off for every channel.
    public static let disableTelemetryPolicyKey = "DisableTelemetry"
    /// The stable bundle identifier every cmux build descends from.
    public static let baseBundleID = "com.cmuxterm.app"

    /// Nil for a build that does not identify as cmux.
    public let channel: Channel?
    public let shouldStart: Bool
    /// `cmux-next@<CFBundleShortVersionString>+<CFBundleVersion>`.
    public let release: String
    /// `CFBundleVersion`.
    public let dist: String
    /// The tag of a tagged DEV or NIGHTLY bundle (`com.cmuxterm.app.debug.<tag>`).
    public let devTag: String?

    public var environment: String { channel?.environment ?? "unknown" }

    /// Every channel crashes at an Objective-C exception's throw site
    /// (cx-r3q, CrashOnExceptions; Release and RC since 2026-10-08).
    public var crashesOnExceptions: Bool { channel != nil }

    public init(
        bundleID: String?,
        shortVersion: String,
        build: String,
        isDebugBuild: Bool,
        telemetryOptIn: Bool,
        managedDisablesTelemetry: Bool,
        processEnvironment: [String: String]
    ) {
        let identity = Self.identity(bundleID: bundleID, isDebugBuild: isDebugBuild)
        channel = identity?.channel
        devTag = identity?.tag
        release = "cmux-next@\(shortVersion)+\(build)"
        dist = build
        shouldStart = identity != nil && telemetryOptIn && !managedDisablesTelemetry
            && !Self.isTestProcess(processEnvironment)
    }

    /// The user's choice in `defaults`: on until the user turns it off.
    public static func telemetryOptIn(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: telemetryKey) == nil ? true : defaults.bool(forKey: telemetryKey)
    }

    /// The channel and tag of a cmux bundle, or nil for a foreign build.
    static func identity(bundleID: String?, isDebugBuild: Bool) -> (channel: Channel, tag: String?)? {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              id == baseBundleID || id.hasPrefix(baseBundleID + ".") else { return nil }
        let rest = id == baseBundleID ? "" : String(id.dropFirst(baseBundleID.count + 1))
        let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
        let tag = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        if isDebugBuild { return (.dev, tag) }
        switch parts.first {
        case nil: return (.release, nil)
        case "nightly": return (.nightly, tag)
        case "rc": return (.rc, tag)
        default: return (.dev, tag)  // debug, staging and other descendants
        }
    }

    /// The main app's test-process rule (`MacSentryStartupPolicy`).
    static func isTestProcess(_ environment: [String: String]) -> Bool {
        if environment["CMUX_TEST_SENTRY_ENABLED"] == "1" { return false }
        if environment["CMUX_TEST_PROCESS"] == "1" { return true }
        let keys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
                    "XCInjectBundle", "XCInjectBundleInto"]
        if keys.contains(where: { environment[$0] != nil }) { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        return environment.keys.contains { $0.hasPrefix("CMUX_UI_TEST_") }
    }
}
