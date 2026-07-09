internal import Foundation

/// The release channel a running cmux build belongs to.
///
/// Classified purely from the process's bundle display/name strings and bundle
/// identifier, so it is a `Sendable` value with no live state. ``current`` reads
/// `Bundle.main`/`ProcessInfo` once; ``detect(bundleNames:bundleIdentifier:)`` is
/// the pure transform behind it and is exercised directly by tests.
public enum BuildFlavor: String, Sendable {
    case dev
    case nightly
    case stable

    /// The flavor of the currently running process, read from `Bundle.main` and
    /// `ProcessInfo`.
    public static var current: BuildFlavor {
        let bundle = Bundle.main
        return detect(
            bundleNames: [
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                ProcessInfo.processInfo.processName,
            ].compactMap { $0 },
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    /// Convenience over ``detect(bundleNames:bundleIdentifier:)`` for a single
    /// candidate name.
    public static func detect(bundleName: String?, bundleIdentifier: String?) -> BuildFlavor {
        detect(bundleNames: [bundleName].compactMap { $0 }, bundleIdentifier: bundleIdentifier)
    }

    /// Classify a build from its candidate display names and bundle identifier.
    ///
    /// A `DEV` token in any name, or a debug-like bundle identifier, wins as
    /// ``dev``; an explicit `com.cmuxterm.app.nightly[.*]` identifier or a
    /// `NIGHTLY` name token yields ``nightly``; everything else is ``stable``.
    public static func detect(bundleNames: [String], bundleIdentifier: String?) -> BuildFlavor {
        if bundleNames.contains(where: containsDevToken) {
            return .dev
        }

        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if isDebugLikeBundleIdentifier(normalizedBundleIdentifier) {
            return .dev
        }
        if normalizedBundleIdentifier == "com.cmuxterm.app.nightly"
            || normalizedBundleIdentifier?.hasPrefix("com.cmuxterm.app.nightly.") == true {
            return .nightly
        }
        if bundleNames.contains(where: containsNightlyToken) {
            return .nightly
        }
        return .stable
    }

    /// Whether the (already-normalized) bundle identifier is a debug build id.
    ///
    /// Byte-identical to `CmuxSettings.SocketControlSettings.isDebugLikeBundleIdentifier`,
    /// inlined here because `CmuxSettings` depends on `CmuxFoundation`: this leaf
    /// package cannot reach up to the socket-control domain without a dependency
    /// cycle. The `com.cmuxterm.app.debug` identifier is a frozen build constant.
    private static func isDebugLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
    }

    private static func containsDevToken(_ name: String) -> Bool {
        containsToken("DEV", in: name)
    }

    private static func containsNightlyToken(_ name: String) -> Bool {
        containsToken("NIGHTLY", in: name)
    }

    private static func containsToken(_ token: String, in name: String) -> Bool {
        name
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { String($0) == token }
    }
}
