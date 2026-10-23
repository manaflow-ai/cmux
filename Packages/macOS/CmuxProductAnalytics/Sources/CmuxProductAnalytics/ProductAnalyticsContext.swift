public import CMUXMobileCore

/// The shared properties attached to every product event and registered as
/// PostHog super properties, so older events (`cmux_daily_active`,
/// `cmux_cloud_vm_request`) carry them too.
public struct ProductAnalyticsContext: Sendable, Equatable {
    /// `CFBundleShortVersionString`.
    public var appVersion: String
    /// `CFBundleVersion`.
    public var appBuild: String
    /// Release channel: `stable`, `nightly`, `rc` or `dev`.
    public var channel: String
    /// `major.minor` of macOS.
    public var osVersion: String
    public var plan: AnalyticsPlan
    public var isSignedIn: Bool
    public var cloudEnabled: Bool
    /// Open workspaces across windows, refreshed when the app becomes active.
    public var workspacesOpen: Int

    /// Creates a context. Account and Cloud state start unknown and are
    /// updated through ``ProductAnalytics/updateContext(_:)``.
    public init(
        appVersion: String,
        appBuild: String,
        channel: String,
        osVersion: String,
        plan: AnalyticsPlan = .unknown,
        isSignedIn: Bool = false,
        cloudEnabled: Bool = false,
        workspacesOpen: Int = 0
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.channel = channel
        self.osVersion = osVersion
        self.plan = plan
        self.isSignedIn = isSignedIn
        self.cloudEnabled = cloudEnabled
        self.workspacesOpen = workspacesOpen
    }

    /// The context as event properties.
    public var properties: [String: AnalyticsValue] {
        [
            "app_version": .string(appVersion),
            "app_build": .string(appBuild),
            "channel": .string(channel),
            "os_version": .string(osVersion),
            "account_plan": .string(plan.rawValue),
            "is_signed_in": .bool(isSignedIn),
            "cloud_enabled": .bool(cloudEnabled),
            "workspaces_open": .string(Self.countBucket(workspacesOpen)),
        ]
    }

    /// `0`, `1`, `2_3`, `4_7`, `8_15` or `16_plus`.
    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1: "1"
        case 2...3: "2_3"
        case 4...7: "4_7"
        case 8...15: "8_15"
        default: "16_plus"
        }
    }
}
