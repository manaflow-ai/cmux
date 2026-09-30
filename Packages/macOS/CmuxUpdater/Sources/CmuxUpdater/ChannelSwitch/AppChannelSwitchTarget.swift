public import Foundation

/// A cmux release line the running app can switch to.
///
/// Stable (`com.cmuxterm.app`) and cmux NIGHTLY (`com.cmuxterm.app.nightly`) are separate
/// apps with their own bundle identifiers and Sparkle feeds, so they install and run side by
/// side. Switching opens the other app, installing it first when it is missing; it never
/// turns one bundle into the other.
public enum AppChannelSwitchTarget: String, Sendable, CaseIterable, Equatable {
    /// The shipping release, bundle identifier `com.cmuxterm.app`.
    case stable
    /// The nightly build of `main`, bundle identifier `com.cmuxterm.app.nightly`.
    case nightly

    /// Bundle identifier of the stable app.
    public static let stableBundleIdentifier = "com.cmuxterm.app"
    /// Bundle identifier of the cmux NIGHTLY app.
    public static let nightlyBundleIdentifier = "com.cmuxterm.app.nightly"
    /// Developer ID team that signs both release apps.
    public static let developerTeamIdentifier = "7WLXT3NR37"

    /// The bundle identifier the installed app must carry.
    public var bundleIdentifier: String {
        switch self {
        case .stable: Self.stableBundleIdentifier
        case .nightly: Self.nightlyBundleIdentifier
        }
    }

    /// The target a running app offers, or `nil` when it offers none.
    ///
    /// Stable offers NIGHTLY and NIGHTLY offers stable. Tagged development builds and any
    /// other bundle identifier offer nothing, so a dev build never installs a release app.
    ///
    /// - Parameter bundleIdentifier: The running app's bundle identifier.
    public static func counterpart(ofBundleIdentifier bundleIdentifier: String?) -> AppChannelSwitchTarget? {
        switch bundleIdentifier {
        case stableBundleIdentifier: .nightly
        case nightlyBundleIdentifier: .stable
        default: nil
        }
    }

    /// The DMG to download when the target app is not installed.
    ///
    /// NIGHTLY uses the per-architecture DMG the updater's manual-download recovery offers.
    /// Stable uses the `cmux-macos.dmg` asset of the release the stable Sparkle feed points at.
    ///
    /// - Parameter architecture: The machine architecture; nightly ships one DMG per architecture.
    public func downloadURL(architecture: UpdateHostArchitecture = .current) -> URL {
        let string = switch self {
        case .stable: UpdateManualDownloadRecovery.stableDownloadURLString
        case .nightly: UpdateManualDownloadRecovery.nightlyDownloadURLString(for: architecture)
        }
        // Both are compile-time constant https URLs.
        return URL(string: string)!
    }
}
