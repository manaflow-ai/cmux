/// The release line a build belongs to, which decides its Sparkle feed.
///
/// Stable and NIGHTLY are separate apps with separate bundle identifiers
/// and feeds; RC shares stable's identity with its own feed. Tagged DEV
/// and staging builds are `development`: they never run Sparkle against a
/// public feed (they are not on the release train), but they may probe it
/// read-only.
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
