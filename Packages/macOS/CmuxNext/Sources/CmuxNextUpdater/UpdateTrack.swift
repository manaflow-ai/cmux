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

    /// `updates.downloadAutomatically` for an install that never set it.
    ///
    /// Off where prod is, so stable and RC ask before the download (Leo, relayed 2026-10-26:
    /// "maybe better as an opt in for normal users"; Leo 2026-10-27: "and the whole
    /// check for updates thing, we can do it more properly to ask before the download + install
    /// step, and likewise for the reboot... to make it more like how it'd be in prod"). A found
    /// update waits on the Update Available step and its Update downloads it. A tagged DEV build
    /// is off too: it never runs Sparkle against a public feed, only the read-only probe.
    ///
    /// On for NIGHTLY and the tip app, the dogfood builds, which Leo asked to be opted in on
    /// (2026-10-26: "I don't want to have to click check for updates to get the update. I just
    /// want the update. Opt in to automatically download. I want to be optted in"): a found update
    /// downloads by itself, with no click.
    ///
    /// Either way the relaunch still waits for Restart to Update on the Update Ready card: the
    /// download setting never installs (``UpdaterService/configure(checkAutomatically:checkInterval:downloadAutomatically:metered:ring:idleInstall:)``
    /// keeps the idle install off whatever it says), so Leo's "likewise for the reboot" holds on
    /// every channel. This is the channel's default only: it fills the effective settings through
    /// ``SettingsBuildDefaults/channel(downloadsAutomatically:)``, never the shared file, and an
    /// explicit value in cmux.json always wins.
    public var downloadsAutomaticallyByDefault: Bool {
        switch self {
        case .nightly: true
        case .stable, .rc, .development: false
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
