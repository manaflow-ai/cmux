/// Self-identifying build + device metadata stamped onto every feedback report.
///
/// Both feedback paths carry this so a report proves which build and device it
/// came from: the privileged direct-to-agent bundle and the email both embed
/// the build type, app version + build number, and OS. Pure value type with no
/// platform imports so the formatting can be unit tested.
public struct MobileFeedbackStamp: Equatable, Sendable {
    /// The distribution channel (dev / beta / prod).
    public let buildType: MobileBuildType
    /// `CFBundleShortVersionString`, e.g. `"0.64.13"`. Empty when unavailable.
    public let appVersion: String
    /// `CFBundleVersion` (build number). Empty when unavailable.
    public let appBuild: String
    /// The running bundle identifier, e.g. `"dev.cmux.app.beta"`.
    public let bundleIdentifier: String
    /// The OS version string, e.g. `"iOS 18.5"`. Empty when unavailable.
    public let osVersion: String
    /// The device model identifier, e.g. `"iPhone16,2"`. Empty when unavailable.
    public let deviceModel: String

    /// Create a stamp from already-resolved fields.
    public init(
        buildType: MobileBuildType,
        appVersion: String,
        appBuild: String,
        bundleIdentifier: String,
        osVersion: String,
        deviceModel: String
    ) {
        self.buildType = buildType
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }

    /// `"0.64.13 (42)"`, or just the version, or `"unknown"` — the version with
    /// the build number in parentheses when both are present.
    public var versionDisplay: String {
        switch (appVersion.isEmpty, appBuild.isEmpty) {
        case (false, false): return "\(appVersion) (\(appBuild))"
        case (false, true): return appVersion
        case (true, false): return "build \(appBuild)"
        case (true, true): return "unknown"
        }
    }

    /// The compact suffix embedded in the email subject so every report is
    /// self-identifying at a glance, e.g. `"[Beta 0.64.13 (42)]"`.
    public var subjectSuffix: String {
        "[\(buildType.displayLabel) \(versionDisplay)]"
    }

    /// A one-line build-identity string for the agent bundle's `build_stamp`,
    /// e.g. `"beta · 0.64.13 (42) · iOS 18.5 · iPhone16,2"`. Empty fields are
    /// dropped so the line stays readable.
    public var agentBuildStamp: String {
        var parts: [String] = [buildType.token, versionDisplay]
        if !osVersion.isEmpty { parts.append(osVersion) }
        if !deviceModel.isEmpty { parts.append(deviceModel) }
        return parts.joined(separator: " · ")
    }
}
