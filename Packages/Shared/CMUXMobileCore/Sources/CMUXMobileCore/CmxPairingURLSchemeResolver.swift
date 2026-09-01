import Foundation

/// Resolves the pairing scheme for the current process without global state.
public struct CmxPairingURLSchemeResolver: Sendable {
    private let currentIOSBundleIdentifier: String?
    private let targetIOSBundleIdentifier: String?
    private let macInstanceTag: String?
    private let isDevelopmentBuild: Bool

    /// Captures the current app identity and any explicit automation override.
    ///
    /// `CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER` remains an automation-only override
    /// for scripts and tests. Normal official Macs emit the canonical App Store
    /// scheme; tagged Mac builds otherwise target their exact same-tag iOS
    /// bundle.
    public init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        currentIOSBundleIdentifier = bundle.bundleIdentifier
        targetIOSBundleIdentifier =
            environment["CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER"]
        macInstanceTag = environment["CMUX_TAG"]
            ?? Self.bundleDerivedMacInstanceTag(
                bundleIdentifier: bundle.bundleIdentifier
            )
        #if DEBUG
        isDevelopmentBuild = true
        #else
        isDevelopmentBuild = false
        #endif
    }

    init(
        currentIOSBundleIdentifier: String?,
        targetIOSBundleIdentifier: String?,
        macInstanceTag: String?,
        isDevelopmentBuild: Bool,
        macBundleIdentifier: String? = nil
    ) {
        self.currentIOSBundleIdentifier = currentIOSBundleIdentifier
        self.targetIOSBundleIdentifier = targetIOSBundleIdentifier
        self.macInstanceTag = macInstanceTag
            ?? Self.bundleDerivedMacInstanceTag(
                bundleIdentifier: macBundleIdentifier
            )
        self.isDevelopmentBuild = isDevelopmentBuild
    }

    /// The exact scheme this process should emit, or `nil` on invalid identity.
    public var resolved: CmxPairingURLScheme? {
        #if os(iOS)
        return CmxPairingURLScheme(
            iOSBundleIdentifier: currentIOSBundleIdentifier
        )
        #else
        if let targetIOSBundleIdentifier {
            return CmxPairingURLScheme(
                iOSBundleIdentifier: targetIOSBundleIdentifier
            )
        }
        let normalizedTag = macInstanceTag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTag == nil || normalizedTag?.isEmpty == true {
            return CmxPairingURLScheme(
                iOSBundleIdentifier: isDevelopmentBuild
                    ? "dev.cmux.ios"
                    : "com.cmux.app"
            )
        }
        // Official Mac lanes must emit the one canonical release QR, never a
        // synthetic tagged-DEV destination. Keep this predicate shared with
        // host compatibility and paired-phone routing.
        if Self.isOfficialMacInstanceTag(normalizedTag) {
            return CmxPairingURLScheme(iOSBundleIdentifier: "com.cmux.app")
        }
        guard let namespace = MobileIOSAppNamespace(
            pairedMacInstanceTag: macInstanceTag
        ) else {
            return nil
        }
        return CmxPairingURLScheme(
            iOSBundleIdentifier: namespace.bundleIdentifier
        )
        #endif
    }

    /// Mirrors the app's bundle-derived lane when a launcher did not export
    /// `CMUX_TAG`. This keeps a Finder/Dock launch of a tagged DEV bundle on
    /// the same exact iOS namespace as a tagged-script launch.
    /// - Parameter bundleIdentifier: The macOS application bundle identifier.
    /// - Returns: The normalized launch tag, an empty string for the untagged
    ///   base DEBUG bundle, or `nil` for an unrecognized bundle.
    public static func bundleDerivedMacInstanceTag(
        bundleIdentifier: String?
    ) -> String? {
        let bundleID = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !bundleID.isEmpty else { return nil }
        let stable = "com.cmuxterm.app"
        let channels: [(prefix: String, fallback: String)] = [
            (stable + ".nightly", "nightly"),
            (stable + ".staging", "staging"),
            (stable + ".rc", "rc"),
            // An unsuffixed base debug bundle is the historical untagged
            // development lane; an empty tag lets `resolved` keep emitting
            // `cmux-ios-dev.cmux.ios`. Only suffixed bundles derive a tag.
            (stable + ".debug", ""),
        ]
        if bundleID == stable { return "default" }
        for channel in channels {
            if bundleID == channel.prefix { return channel.fallback }
            let prefix = channel.prefix + "."
            guard bundleID.hasPrefix(prefix) else { continue }
            let suffix = String(bundleID.dropFirst(prefix.count))
            return Self.sanitizeMacInstanceTag(suffix) ?? channel.fallback
        }
        return nil
    }

    /// Returns whether a normalized non-empty Mac tag names a distributed
    /// release lane rather than a tagged development build.
    /// - Parameter instanceTag: The Mac instance tag to classify.
    /// - Returns: `true` for `default`, `nightly`, `rc`, or `staging`.
    public static func isOfficialMacInstanceTag(_ instanceTag: String?) -> Bool {
        guard let instanceTag else { return false }
        let normalized = instanceTag.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return officialMacInstanceTags.contains(normalized)
    }

    private static let officialMacInstanceTags: Set<String> = [
        "default",
        "nightly",
        "rc",
        "staging",
    ]

    private static func sanitizeMacInstanceTag(_ rawValue: String) -> String? {
        let normalized = rawValue.lowercased()
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-")
        )
        var result = ""
        var previousWasSeparator = false
        for scalar in normalized.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
