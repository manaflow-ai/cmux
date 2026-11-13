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

    /// `updates.downloadAutomatically` for an install that never set it. On cmux NEXT's nightly ring
    /// (NEXT, the tip app) it is on: a new nightly downloads, is verified and is unpacked in the
    /// background, and the Update Ready card's Restart to Update is the one click left (Leo
    /// 2026-11-08: "did we do the thing where the update, like, auto downloads, auto installs in the
    /// background and all that stuff, and then it's just you click the button and that just simply
    /// restarts the app really quickly?"; 2026-11-10: "the nightly automatically downloads and
    /// installs/unpacks and you simply click and it restarts with the new version"). The relaunch
    /// still waits for that click (the nightly restart policy keeps the idle install off).
    /// Elsewhere it stays off, so a found update asks before it downloads: stable and RC (claude-sr2
    /// 2026-10-26, relaying Leo: "maybe better as an opt in for normal users"), classic NIGHTLY and
    /// tagged DEV builds (Leo 2026-10-27: "ask before the download + install step").
    public var downloadsAutomaticallyByDefault: Bool {
        switch self {
        case .nightlyNext: true
        case .stable, .rc, .nightly, .development: false
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
