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

    /// cmux NEXT DEV's bundle id (the Release compile of feat-cmux-next, docs/cmux-next/dev-daily.md).
    public static let tipBundleIdentifier = AppChannelSwitchTarget.devBundleIdentifier
    /// The feed main's DEV publisher stamps into that bundle. Its path holds `/nightly-next/`, so
    /// it resolves like cmux NEXT's nightly feed: per architecture, with rings.
    public static let tipFeedPrefix = "https://files.cmux.com/nightly-next/tip/"

    /// The tip app: cmux NEXT DEV as published, which follows the tip feed and runs Sparkle.
    /// Both the exact bundle id and the stamped feed are required, so a local `reload.sh --tag next`
    /// build (same id, the default feed) and any other DEV or staging build stay development.
    public var isTipBuild: Bool {
        bundleIdentifier == Self.tipBundleIdentifier && infoFeedURL?.hasPrefix(Self.tipFeedPrefix) == true
    }

    public var track: UpdateTrack {
        if UpdateTrack.isDevelopmentBundle(bundleIdentifier), !isTipBuild { return .development }
        switch UpdateFeedResolver().resolve(infoFeedURL: infoFeedURL).channel {
        case .stable: return .stable
        case .nightly: return .nightly
        case .nightlyNext: return .nightlyNext
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

    /// The other release app this one can switch to, by bundle id: stable <-> NIGHTLY, and
    /// cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`) <-> the tip app (cmux NEXT DEV as
    /// published); nil for local DEV, staging and RC builds. A local `reload.sh --tag next`
    /// build shares the tip app's bundle id but not its feed, so it offers nothing. The legacy
    /// NEXT build signed as cmux NIGHTLY (`com.cmuxterm.app.nightly`) keeps NIGHTLY's stable
    /// counterpart (`UpdateTrackMatrixTests` pins each).
    public var channelSwitchTarget: AppChannelSwitchTarget? {
        if bundleIdentifier == Self.tipBundleIdentifier, !isTipBuild { return nil }
        return AppChannelSwitchTarget.counterpart(ofBundleIdentifier: bundleIdentifier)
    }
}
