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
    /// The source commit this bundle was built from (`CMUXCommit`), when stamped by CI.
    public var sourceCommit: String?

    public init(bundleIdentifier: String?, shortVersion: String, build: String, minimumSystemVersion: SystemVersion?,
                infoFeedURL: String?, hasPublicKey: Bool, sourceCommit: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.build = build
        self.sourceCommit = Self.normalizedCommit(sourceCommit)
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
            sourceCommit: Self.normalizedCommit(info["CMUXCommit"] as? String),
            minimumSystemVersion: (info["LSMinimumSystemVersion"] as? String).flatMap(SystemVersion.init),
            infoFeedURL: info["SUFeedURL"] as? String,
            // An unsubstituted `$(SPARKLE_PUBLIC_KEY)` is not a key.
            hasPublicKey: !key.isEmpty && !key.hasPrefix("$(")
        )
    }

    static func normalizedCommit(_ value: String?) -> String? {
        guard let value else { return nil }
        let commit = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (7...40).contains(commit.count), commit.allSatisfy(\.isHexDigit) else { return nil }
        return commit
    }

    /// The running app.
    public static func main() -> UpdateBuildIdentity {
        UpdateBuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// cmux NEXT DEV's bundle id (the Release compile of feat-cmux-next, docs/cmux-next/dev-daily.md).
    public static let tipBundleIdentifier = "com.cmuxterm.app.debug.next"
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

    /// The other cmux NEXT feed. DEV (`tip`) and NIGHTLY (`next`) share the
    /// signing key, but publish independently so each app normally reads only
    /// its own feed. Cross-channel checks opt into this counterpart explicitly.
    public func counterpartFeed(architecture: UpdateHostArchitecture = .current) -> String? {
        let current = feed(architecture: architecture)
        guard current.channel == .nightlyNext, let url = URL(string: current.url) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        guard path.contains("/nightly-next/next/") || path.contains("/nightly-next/tip/") else { return nil }
        if path.contains("/nightly-next/next/") {
            components?.host = "files.cmux.com"
            components?.path = path.replacingOccurrences(of: "/nightly-next/next/", with: "/nightly-next/tip/")
        } else {
            components?.host = "files-next.cmux.com"
            components?.path = path.replacingOccurrences(of: "/nightly-next/tip/", with: "/nightly-next/next/")
        }
        return components?.url?.absoluteString
    }

    /// Why Sparkle must not run, or nil when it may.
    public func sparkleDisabledReason(managedPolicyDisablesUpdates: Bool) -> UpdateDisabledReason? {
        if track == .development { return .developmentBuild }
        if !hasPublicKey { return .missingPublicKey }
        if managedPolicyDisablesUpdates { return .managedPolicy }
        return nil
    }

    /// The other release app this one can switch to (stable <-> NIGHTLY), by bundle id;
    /// nil for DEV, staging and RC builds. cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`)
    /// and the tip app have none; the legacy NEXT build signed as cmux NIGHTLY
    /// (`com.cmuxterm.app.nightly`) keeps NIGHTLY's stable counterpart
    /// (`UpdateTrackMatrixTests` pins each).
    public var channelSwitchTarget: AppChannelSwitchTarget? {
        AppChannelSwitchTarget.counterpart(ofBundleIdentifier: bundleIdentifier)
    }
}
