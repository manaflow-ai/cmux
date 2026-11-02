/// The release line a build belongs to, which decides its Sparkle feed.
///
/// Stable and NIGHTLY are separate apps with separate bundle identifiers
/// and feeds; RC shares stable's identity with its own feed. Tagged DEV
/// and staging builds are `development`: they never run Sparkle against a
/// public feed (they are not on the release train), but they may probe it
/// read-only. The one exception is the tip app (cmux NEXT DEV stamped with
/// the tip feed, ``UpdateBuildIdentity/isTipBuild``), which is `nightlyNext`.
///
/// The raw value is the `track` of `updates.status` and the probe result.
nonisolated public enum UpdateTrack: String, Sendable, CaseIterable, Codable {
    case stable
    /// Classic cmux NIGHTLY: main's `/nightly/` feed.
    case nightly
    case rc
    case development
    /// cmux NEXT's nightly ring: a `/nightly-next/` feed, with its own release and
    /// Sparkle key. cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`), the legacy NEXT
    /// build signed as cmux NIGHTLY and the tip app all read one.
    case nightlyNext = "nightly-next"

    /// Whether `bundleIdentifier` is a DEV (`com.cmuxterm.app.debug[.<tag>]`) or staging
    /// (`com.cmuxterm.app.staging[.<tag>]`) build (cmux-updater-core `updater_build_rules`).
    /// When the rules do not answer, no build counts as one: it stays guarded and runs no harness.
    public static func isDevelopmentBundle(_ bundleIdentifier: String?) -> Bool {
        UpdateBuildIdentity(bundleIdentifier: bundleIdentifier, shortVersion: "", build: "", minimumSystemVersion: nil,
                            infoFeedURL: nil, hasPublicKey: false).rules()?.developmentBundle ?? false
    }
}

/// Why Sparkle does not run in this process. The read-only probe still works.
nonisolated public enum UpdateDisabledReason: String, Sendable, Codable {
    /// A tagged DEV or staging build.
    case developmentBuild = "development_build"
    /// `SUPublicEDKey` is missing or was never substituted at build time, so
    /// Sparkle could not verify an update.
    case missingPublicKey = "missing_public_key"
    /// A configuration profile forces `DisableAutoUpdate`.
    case managedPolicy = "managed_policy"
}
