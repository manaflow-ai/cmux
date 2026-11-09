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

    /// Whether a test appcast may replace the baked feed (`updates.test_feed`,
    /// `debug.updater`, a pinned test feed): DEV and both nightly rings, never
    /// stable or RC.
    public var allowsTestFeed: Bool {
        switch self {
        case .nightly, .nightlyNext, .development: true
        case .stable, .rc: false
        }
    }

    /// Whether `bundleIdentifier` is a DEV (`com.cmuxterm.app.debug[.<tag>]`)
    /// or staging (`com.cmuxterm.app.staging[.<tag>]`) build.
    public static func isDevelopmentBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        for base in ["com.cmuxterm.app.debug", "com.cmuxterm.app.staging"] {
            if bundleIdentifier == base || bundleIdentifier.hasPrefix(base + ".") { return true }
        }
        return false
    }

    /// `updates.downloadAutomatically` for an install that never set it: on, on every channel. A
    /// found update downloads in the background, and the staged update waits on the Update Ready
    /// card for Restart to Update (the nightly restart policy, which keeps the idle install and the
    /// install on quit off). Leo 2026-11-07, on "download in the background by default, but only
    /// install when you click restart": "Yeah, let's do that, man. Let's get it done." It was off
    /// on every channel from Leo 2026-10-27 ("ask before the download + install step"). Turning
    /// it off makes a found update wait on the Update Available step for its Update click.
    public var downloadsAutomaticallyByDefault: Bool {
        switch self {
        case .stable, .rc, .nightly, .nightlyNext, .development: true
        }
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
