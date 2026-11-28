@preconcurrency import Sparkle

/// Picks what a feed offers, with Sparkle's own version comparison
/// (`SUStandardVersionComparator`) and its OS filter: an item is offered
/// only when `minimumSystemVersion <= macOS <= maximumSystemVersion`, and
/// the newest offered item wins.
nonisolated public enum AppcastSelector {
    public static func select(from items: [AppcastItem], currentBuild: String, system: SystemVersion) -> UpdateProbeOutcome {
        let newest = items.max { isOlder($0.version, than: $1.version) }
        let newestCompatible = items.filter { $0.supports(system) }.max { isOlder($0.version, than: $1.version) }
        if let newestCompatible, isOlder(currentBuild, than: newestCompatible.version) {
            return .updateAvailable(newestCompatible)
        }
        if let newest, isOlder(currentBuild, than: newest.version), !newest.supports(system) {
            let required = newest.minimumSystemVersion ?? system
            return .requiresNewerSystem(newest, required: required)
        }
        return .upToDate(latest: newestCompatible)
    }

    /// Sparkle's ordering of `CFBundleVersion` strings.
    public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(lhs, toVersion: rhs) == .orderedAscending
    }
}
