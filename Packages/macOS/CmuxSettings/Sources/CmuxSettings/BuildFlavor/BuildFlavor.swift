import Foundation

/// The release channel this build belongs to, detected from its bundle names and identifier.
///
/// Telemetry, checkout attribution, and host identity report it as a channel
/// token (`dev`, `nightly`, `rc`, `stable`).
public enum BuildFlavor: String, Sendable {
    /// A local or tagged debug build.
    case dev
    /// The nightly channel bundle.
    case nightly
    /// The release-candidate channel bundle.
    case rc
    /// The stable release bundle, and anything no other channel claims.
    case stable

    /// The flavor of the running app, from `Bundle.main` and the process name.
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

    /// Detects the flavor from one bundle name and a bundle identifier.
    ///
    /// - Parameters:
    ///   - bundleName: The bundle's display or short name, if any.
    ///   - bundleIdentifier: The bundle identifier, if any.
    /// - Returns: The detected flavor; ``stable`` when nothing else matches.
    public static func detect(bundleName: String?, bundleIdentifier: String?) -> BuildFlavor {
        detect(bundleNames: [bundleName].compactMap { $0 }, bundleIdentifier: bundleIdentifier)
    }

    /// Detects the flavor from every bundle name and a bundle identifier.
    ///
    /// A `DEV` token in any name or a debug-like identifier wins, then a
    /// release channel, then ``stable``.
    ///
    /// - Parameters:
    ///   - bundleNames: Display name, bundle name, and process name candidates.
    ///   - bundleIdentifier: The bundle identifier, if any.
    /// - Returns: The detected flavor.
    public static func detect(bundleNames: [String], bundleIdentifier: String?) -> BuildFlavor {
        if bundleNames.contains(where: containsDevToken) {
            return .dev
        }

        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if SocketControlSettings.isDebugLikeBundleIdentifier(normalizedBundleIdentifier) {
            return .dev
        }
        if let channel = releaseChannel(normalizedBundleIdentifier: normalizedBundleIdentifier, bundleNames: bundleNames) {
            return channel
        }
        return .stable
    }

    private static func containsDevToken(_ name: String) -> Bool {
        containsToken("DEV", in: name)
    }

    /// Whether `name` contains `token` as a whole alphanumeric word, ignoring case.
    ///
    /// - Parameters:
    ///   - token: The uppercase token to look for.
    ///   - name: The bundle name to search.
    /// - Returns: `true` when a word of `name` equals `token`.
    public static func containsToken(_ token: String, in name: String) -> Bool {
        name
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { String($0) == token }
    }
}
