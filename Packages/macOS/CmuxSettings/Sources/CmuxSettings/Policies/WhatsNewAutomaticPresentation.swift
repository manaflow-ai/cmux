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
        /// A fresh install: record the current release as seen, show nothing.
        case recordCurrent
    }

    public init() {}

    /// What a launch does once its catalog load has returned.
    public enum LaunchOutcome: Equatable, Sendable {
        /// Do nothing at all.
        case suppress
        /// Set the quiet indicator on the sidebar help button.
        case indicate
        /// Open the recap as a sheet on a main terminal window.
        case presentSheet
    }

    /// Resolves what a launch does after its catalog load, against the values
    /// the user or another code path may have changed while it was in flight.
    ///
    /// `decide` runs before the load, which takes as long as a network fetch,
    /// so both of its inputs can be stale by the time the catalog arrives.
    ///
    /// - Parameters:
    ///   - decidedToPresent: Whether `decide` authorized a presentation for
    ///     this launch rather than only the quiet indicator.
    ///   - liveMode: The `app.whatsNew` setting as it reads now.
    ///   - announcedVersion: The seen record `decide` read.
    ///   - liveAnnouncedVersion: The seen record as it reads now. It differs
    ///     when an on-demand open landed first and consumed this version's one
    ///     announcement.
    public static func launchOutcome(
        decidedToPresent: Bool,
        liveMode: WhatsNewPresentationMode,
        announcedVersion: String?,
        liveAnnouncedVersion: String?
    ) -> LaunchOutcome {
        guard liveMode != .off else { return .suppress }
        return liveMode == .sheet ? .presentSheet : .indicate
    }


    /// The launch decision.
    ///
    /// - Parameters:
    ///   - mode: The `app.whatsNew` setting.
    ///   - flavor: The running build's channel.
    ///   - currentVersion: `CFBundleShortVersionString` of the running build.
    ///   - lastSeenVersion: The release key recorded when the user last saw
    ///     (or was shown) the recap, or `nil` when nothing is recorded.
    ///   - isFirstRun: No earlier install of cmux ran on this Mac. With
    ///     nothing recorded, a first run is a new user, not an update, so it
    ///     announces nothing; an earlier install is an update from a version
    ///     that predates What's New.
    /// - Returns: The decision. `since` is the last seen release key, so the
    ///   caller shows only highlights after it.
    public func decide(
        mode: WhatsNewPresentationMode,
        flavor: BuildFlavor,
        currentVersion: String,
        lastSeenVersion: String?,
        isFirstRun: Bool = false
    ) -> Decision {
        guard let current = Self.releaseKey(currentVersion) else { return .none }
        let lastSeen = lastSeenVersion.flatMap(Self.releaseKey)
        if lastSeen == nil, isFirstRun { return .recordCurrent }
        guard mode != .off, flavor != .dev else { return .none }
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
        let hasTagPrefix = trimmed.first.map { $0 == "v" || $0 == "V" } ?? false
        let withoutPrefix = hasTagPrefix ? String(trimmed.dropFirst()) : trimmed
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
