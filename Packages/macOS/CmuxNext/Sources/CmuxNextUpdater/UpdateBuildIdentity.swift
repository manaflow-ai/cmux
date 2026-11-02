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

    /// The identity `Info.plist` describes, read by the update rules (cmux-updater-core
    /// `updater_build_info`): missing versions read as "0", an unsubstituted
    /// `$(SPARKLE_PUBLIC_KEY)` is not a key. When the rules do not answer, the identity has no
    /// key, so Sparkle never runs on it.
    public init(infoDictionary info: [String: Any]) {
        let request = BuildInfoRequest(bundleIdentifier: info["CFBundleIdentifier"] as? String,
                                       shortVersion: info["CFBundleShortVersionString"] as? String,
                                       build: info["CFBundleVersion"] as? String,
                                       minimumSystemVersion: info["LSMinimumSystemVersion"] as? String,
                                       feedUrl: info["SUFeedURL"] as? String,
                                       publicKey: info["SUPublicEDKey"] as? String)
        let answer: BuildInfoAnswer? = UpdaterRules().call("updater_build_info", json: request)
        self.init(bundleIdentifier: request.bundleIdentifier, shortVersion: answer?.shortVersion ?? "",
                  build: answer?.build ?? "", minimumSystemVersion: answer?.minimumSystemVersion,
                  infoFeedURL: request.feedUrl, hasPublicKey: answer?.hasPublicKey ?? false)
    }

    /// The running app.
    public static func main() -> UpdateBuildIdentity {
        UpdateBuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// cmux NEXT DEV's bundle id (the Release compile of feat-cmux-next, docs/cmux-next/dev-daily.md).
    public static let tipBundleIdentifier = AppChannelSwitchTarget.devBundleIdentifier

    /// The tip app: cmux NEXT DEV as published, which follows the tip feed and runs Sparkle.
    /// Both the exact bundle id and the stamped feed are required, so a local `reload.sh --tag next`
    /// build (same id, the default feed) and any other DEV or staging build stay development.
    public var isTipBuild: Bool { rules()?.isTipBuild ?? false }

    /// The release line (development when the rules do not answer: Sparkle never runs then).
    public var track: UpdateTrack { rules()?.track ?? .development }

    /// Whether a test appcast may replace the baked feed: DEV and both nightly rings, never
    /// stable or RC.
    public var allowsTestFeed: Bool { rules()?.allowsTestFeed ?? false }

    /// `updates.downloadAutomatically` for an install that never set it: off on every channel
    /// (Leo 2026-10-27, claude-sr2 2026-10-26); turning it on is the opt-in.
    public var downloadsAutomaticallyByDefault: Bool { rules()?.downloadsAutomaticallyByDefault ?? false }

    /// The release-line rules of this identity (cmux-updater-core `updater_build_rules`). The
    /// feed's channel comes from ``UpdateFeedResolver``, which Sparkle's delegate also reads.
    func rules(managedPolicyDisablesUpdates: Bool = false) -> BuildRules? {
        let request = BuildRulesRequest(bundleIdentifier: bundleIdentifier, infoFeedUrl: infoFeedURL, hasPublicKey: hasPublicKey,
                                        feedChannel: UpdateFeedResolver().resolve(infoFeedURL: infoFeedURL).channel.rawValue,
                                        managedPolicyDisablesUpdates: managedPolicyDisablesUpdates)
        return UpdaterRules().call("updater_build_rules", json: request)
    }

    /// The feed Sparkle (and the probe) read for this machine: nightly and RC
    /// feeds are per architecture, stable is one feed.
    public func feed(architecture: UpdateHostArchitecture = .current) -> UpdateFeedResolver.Resolution {
        UpdateFeedResolver(hostArchitecture: architecture).resolve(infoFeedURL: infoFeedURL)
    }

    /// Why Sparkle must not run, or nil when it may (development when the rules do not answer).
    public func sparkleDisabledReason(managedPolicyDisablesUpdates: Bool) -> UpdateDisabledReason? {
        guard let rules = rules(managedPolicyDisablesUpdates: managedPolicyDisablesUpdates) else { return .developmentBuild }
        return rules.disabledReason
    }

    /// The other release app this one can switch to, by bundle id: stable <-> NIGHTLY, and
    /// cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`) <-> the tip app (cmux NEXT DEV as
    /// published); nil for local DEV, staging and RC builds. A local `reload.sh --tag next`
    /// build shares the tip app's bundle id but not its feed, so it offers nothing. The legacy
    /// NEXT build signed as cmux NIGHTLY (`com.cmuxterm.app.nightly`) keeps NIGHTLY's stable
    /// counterpart (`UpdateTrackMatrixTests` pins each).
    public var channelSwitchTarget: AppChannelSwitchTarget? {
        guard rules()?.offersChannelSwitch == true else { return nil }
        return AppChannelSwitchTarget.counterpart(ofBundleIdentifier: bundleIdentifier)
    }

    /// The answer of `updater_build_rules`.
    nonisolated struct BuildRules: Decodable, Sendable {
        var isTipBuild: Bool
        var developmentBundle: Bool
        var track: UpdateTrack
        var allowsTestFeed: Bool
        var downloadsAutomaticallyByDefault: Bool
        var disabledReason: UpdateDisabledReason?
        var offersChannelSwitch: Bool
    }
}

nonisolated private struct BuildInfoRequest: Encodable {
    var bundleIdentifier: String?
    var shortVersion: String?
    var build: String?
    var minimumSystemVersion: String?
    var feedUrl: String?
    var publicKey: String?
}

nonisolated private struct BuildInfoAnswer: Decodable {
    var shortVersion: String
    var build: String
    var minimumSystemVersion: SystemVersion?
    var hasPublicKey: Bool
}

nonisolated private struct BuildRulesRequest: Encodable {
    var bundleIdentifier: String?
    var infoFeedUrl: String?
    var hasPublicKey: Bool
    var feedChannel: String
    var managedPolicyDisablesUpdates: Bool
}
