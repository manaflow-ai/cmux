public import Foundation

/// A cmux release line the running app can switch to.
///
/// Stable (`com.cmuxterm.app`) and cmux NIGHTLY (`com.cmuxterm.app.nightly`) are separate
/// apps with their own bundle identifiers and Sparkle feeds, so they install and run side by
/// side. Switching opens the other app, installing it first when it is missing; it never
/// turns one bundle into the other. cmux NEXT's NIGHTLY (`com.cmuxterm.app.nightly.cmux-next`)
/// and its DEV app (`com.cmuxterm.app.debug.next`) are such a pair too.
public enum AppChannelSwitchTarget: String, Sendable, CaseIterable, Equatable {
    /// The shipping release, bundle identifier `com.cmuxterm.app`.
    case stable
    /// The nightly build of `main`, bundle identifier `com.cmuxterm.app.nightly`.
    case nightly
    /// cmux NEXT's NIGHTLY, bundle identifier `com.cmuxterm.app.nightly.cmux-next`.
    case nightlyNext = "nightly-next"
    /// cmux NEXT DEV, the signed build of the feat-cmux-next tip between nightlies,
    /// bundle identifier `com.cmuxterm.app.debug.next` (docs/cmux-next/dev-daily.md).
    case dev

    /// Bundle identifier of the stable app.
    public static let stableBundleIdentifier = "com.cmuxterm.app"
    /// Bundle identifier of the cmux NIGHTLY app.
    public static let nightlyBundleIdentifier = "com.cmuxterm.app.nightly"
    /// Bundle identifier of cmux NEXT's NIGHTLY app.
    public static let nightlyNextBundleIdentifier = "com.cmuxterm.app.nightly.cmux-next"
    /// Bundle identifier of the cmux NEXT DEV app.
    public static let devBundleIdentifier = "com.cmuxterm.app.debug.next"
    /// The cmux NEXT DEV app as the DEV publisher uploads it: one `ditto --keepParent` zip.
    public static let devDownloadURLString = "https://github.com/manaflow-ai/cmux/releases/download/cmux-next-dev/cmux-NEXT-DEV.zip"
    /// Developer ID team that signs every cmux app.
    public static let developerTeamIdentifier = "7WLXT3NR37"

    /// The bundle identifier the installed app must carry.
    public var bundleIdentifier: String {
        switch self {
        case .stable: Self.stableBundleIdentifier
        case .nightly: Self.nightlyBundleIdentifier
        case .nightlyNext: Self.nightlyNextBundleIdentifier
        case .dev: Self.devBundleIdentifier
        }
    }

    /// How the download is packed.
    public enum Archive: String, Sendable, Equatable {
        /// A disk image, mounted to copy the app out.
        case diskImage = "dmg"
        /// A zip with the app at its root, extracted to copy the app out.
        case zip
    }

    /// How ``downloadURL(architecture:)`` is packed: DEV ships a zip, the others a DMG.
    public var archive: Archive {
        self == .dev ? .zip : .diskImage
    }

    /// Whether `name` (an action or CLI argument) asks for this target. cmux NEXT's NIGHTLY
    /// also answers to `nightly`, the word its app and the DEV app show for it.
    public func isNamed(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == rawValue || (self == .nightlyNext && name == Self.nightly.rawValue)
    }

    /// The target a running app offers, or `nil` when it offers none.
    ///
    /// Stable offers NIGHTLY and NIGHTLY offers stable; cmux NEXT's NIGHTLY offers DEV and DEV
    /// offers cmux NEXT's NIGHTLY. Tagged development builds and any other bundle identifier
    /// offer nothing, so a local dev build never installs a release app. A local build that
    /// shares DEV's bundle identifier is told apart by its feed (`UpdateBuildIdentity`).
    ///
    /// - Parameter bundleIdentifier: The running app's bundle identifier.
    public static func counterpart(ofBundleIdentifier bundleIdentifier: String?) -> AppChannelSwitchTarget? {
        switch bundleIdentifier {
        case stableBundleIdentifier: .nightly
        case nightlyBundleIdentifier: .stable
        case nightlyNextBundleIdentifier: .dev
        case devBundleIdentifier: .nightlyNext
        default: nil
        }
    }

    /// The DMG to download when the target app is not installed.
    ///
    /// NIGHTLY and cmux NEXT's NIGHTLY use the per-architecture DMG the updater's
    /// manual-download recovery offers. Stable uses the `cmux-macos.dmg` asset of the release
    /// the stable Sparkle feed points at. DEV uses the zip of the `cmux-next-dev` release.
    ///
    /// - Parameter architecture: The machine architecture; nightly ships one DMG per architecture.
    /// - Returns: The DMG URL; `nil` only if a constant failed to parse (a test pins that both parse).
    public func downloadURL(architecture: UpdateHostArchitecture = .current) -> URL? {
        let string = switch self {
        case .stable: UpdateManualDownloadRecovery.stableDownloadURLString
        case .nightly: UpdateManualDownloadRecovery.nightlyDownloadURLString(for: architecture)
        case .nightlyNext: UpdateManualDownloadRecovery.nightlyNextDownloadURLString(for: architecture)
        case .dev: Self.devDownloadURLString
        }
        // All are compile-time constant https URLs.
        return URL(string: string)
    }
}
