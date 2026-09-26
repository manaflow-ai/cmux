import Foundation

/// Decides what What's New does on its own at launch.
///
/// Versions are compared by their release key: the leading dotted-numeric
/// part of the marketing version, so `0.64.25`, `0.64.25-nightly.812`, and
/// `0.64.25-rc.1` share the key `0.64.25`. Nightly and RC builds therefore
/// announce each release once, never once per build. Dev builds never announce
/// on their own; the on-demand entrypoints still work there.
public struct WhatsNewAutomaticPresentation: Sendable {
    /// What to do at launch.
    public enum Decision: Equatable, Sendable {
        /// Nothing automatic.
        case none
        /// Show the quiet indicator for highlights newer than `since`.
        case indicate(since: String?)
        /// Present the recap once for highlights newer than `since`.
        case present(since: String?)
    }

    public init() {}

    /// The launch decision.
    ///
    /// - Parameters:
    ///   - mode: The `app.whatsNew` setting.
    ///   - flavor: The running build's channel.
    ///   - currentVersion: `CFBundleShortVersionString` of the running build.
    ///   - lastSeenVersion: The release key recorded when the user last saw
    ///     (or was shown) the recap, or `nil` when nothing is recorded.
    /// - Returns: The decision. `since` is the last seen release key, so the
    ///   caller shows only highlights after it.
    public func decide(
        mode: WhatsNewPresentationMode,
        flavor: BuildFlavor,
        currentVersion: String,
        lastSeenVersion: String?
    ) -> Decision {
        guard mode != .off, flavor != .dev else { return .none }
        guard let current = Self.releaseKey(currentVersion) else { return .none }
        let lastSeen = lastSeenVersion.flatMap(Self.releaseKey)
        guard lastSeen != current else { return .none }
        switch mode {
        case .off: return .none
        case .quiet: return .indicate(since: lastSeen)
        case .sheet: return .present(since: lastSeen)
        }
    }

    /// The leading dotted-numeric part of a version string, or `nil` when the
    /// string does not start with a number (`"0.64.25-nightly.3"` gives
    /// `"0.64.25"`).
    public static func releaseKey(_ version: String) -> String? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        var components: [Substring] = []
        for part in withoutPrefix.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { break }
            components.append(digits)
            // A suffix such as "25-nightly" ends the numeric part.
            if digits.count != part.count { break }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: ".")
    }
}
