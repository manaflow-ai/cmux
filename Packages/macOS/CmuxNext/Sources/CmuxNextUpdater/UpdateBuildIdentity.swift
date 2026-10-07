public import CmuxUpdater
import Foundation

/// What the running bundle says about itself for updates: identity,
/// version, the macOS floor it was built for, and its Sparkle feed.
///
/// Built from `Info.plist` (``init(infoDictionary:)``), so tests describe
/// any channel without a real bundle.
nonisolated public struct UpdateBuildIdentity: Sendable, Equatable {
    public var bundleIdentifier: String?
    /// `CFBundleShortVersionString`, shown to people.
    public var shortVersion: String
    /// `CFBundleVersion`, which Sparkle compares with `sparkle:version`.
    public var build: String
    /// `LSMinimumSystemVersion` (26.0 for cmux-next).
    public var minimumSystemVersion: SystemVersion?
    /// `SUFeedURL` as baked into the bundle.
    public var infoFeedURL: String?
    /// Whether `SUPublicEDKey` holds a real key.
    public var hasPublicKey: Bool

    public init(bundleIdentifier: String?, shortVersion: String, build: String, minimumSystemVersion: SystemVersion?,
                infoFeedURL: String?, hasPublicKey: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.infoFeedURL = infoFeedURL
        self.hasPublicKey = hasPublicKey
    }

    public init(infoDictionary info: [String: Any]) {
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            minimumSystemVersion: (info["LSMinimumSystemVersion"] as? String).flatMap(SystemVersion.init),
            infoFeedURL: info["SUFeedURL"] as? String,
            // An unsubstituted `$(SPARKLE_PUBLIC_KEY)` is not a key.
            hasPublicKey: !key.isEmpty && !key.hasPrefix("$(")
        )
    }

    /// The running app.
    public static func main() -> UpdateBuildIdentity {
        UpdateBuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    public var track: UpdateTrack {
        if UpdateTrack.isDevelopmentBundle(bundleIdentifier) { return .development }
        switch UpdateFeedResolver().resolve(infoFeedURL: infoFeedURL).channel {
        case .stable: return .stable
        case .nightly, .nightlyNext: return .nightly
        case .rc: return .rc
        }
    }

    /// The feed Sparkle (and the probe) read for this machine: nightly and RC
    /// feeds are per architecture, stable is one feed.
    public func feed(architecture: UpdateHostArchitecture = .current) -> UpdateFeedResolver.Resolution {
        UpdateFeedResolver(hostArchitecture: architecture).resolve(infoFeedURL: infoFeedURL)
    }

    /// Why Sparkle must not run, or nil when it may.
    public func sparkleDisabledReason(managedPolicyDisablesUpdates: Bool) -> UpdateDisabledReason? {
        if track == .development { return .developmentBuild }
        if !hasPublicKey { return .missingPublicKey }
        if managedPolicyDisablesUpdates { return .managedPolicy }
        return nil
    }

    /// The other release app this one can switch to (stable <-> NIGHTLY);
    /// nil for DEV, staging and RC builds.
    public var channelSwitchTarget: AppChannelSwitchTarget? {
        AppChannelSwitchTarget.counterpart(ofBundleIdentifier: bundleIdentifier)
    }
}
