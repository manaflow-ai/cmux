/// The release line a build belongs to, which decides its Sparkle feed.
///
/// Stable and NIGHTLY are separate apps with separate bundle identifiers
/// and feeds; RC shares stable's identity with its own feed. Tagged DEV
/// and staging builds are `development`: they never run Sparkle against a
/// public feed (they are not on the release train), but they may probe it
/// read-only. The one exception is the tip app (cmux NEXT DEV stamped with
/// the tip feed, ``UpdateBuildIdentity/isTipBuild``), which is `nightly`.
nonisolated public enum UpdateTrack: String, Sendable, CaseIterable, Codable {
    case stable
    case nightly
    case rc
    case development

    /// Whether `bundleIdentifier` is a DEV (`com.cmuxterm.app.debug[.<tag>]`)
    /// or staging (`com.cmuxterm.app.staging[.<tag>]`) build.
    public static func isDevelopmentBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        for base in ["com.cmuxterm.app.debug", "com.cmuxterm.app.staging"] {
            if bundleIdentifier == base || bundleIdentifier.hasPrefix(base + ".") { return true }
        }
        return false
    }

    /// `updates.downloadAutomatically` for an install that never set it (claude-sr2 2026-10-26,
    /// relaying Leo: "i also feel like the forced auto download for updates is convienient for me,
    /// maybe better as an opt in for normal users"): on in the dogfood apps (NIGHTLY, the tip app
    /// and DEV builds), off in stable and RC, where a found update waits for a click.
    public var downloadsAutomaticallyByDefault: Bool {
        switch self {
        case .nightly, .development: true
        case .stable, .rc: false
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
