public import Foundation

/// Chooses a direct-download recovery URL for update failures where the in-app install path is
/// broken but fetching the active channel manually is still safe.
public struct UpdateManualDownloadRecovery: Sendable {
    private let stableDownloadURLString: String
    private let nightlyDownloadURLString: String
    private let rcDownloadURLString: String

    /// The direct stable DMG URL: the `cmux-macos.dmg` asset of the release the stable feed
    /// (`releases/latest/download/appcast.xml`) points at.
    public static let stableDownloadURLString = "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg"

    /// Creates a recovery resolver.
    ///
    /// - Parameters:
    ///   - stableDownloadURLString: Direct DMG URL for the stable channel.
    ///   - nightlyDownloadURLString: Direct DMG URL for the nightly channel. Defaults to the
    ///     nightly DMG for `hostArchitecture`, since nightly ships one DMG per architecture.
    ///   - rcDownloadURLString: Direct DMG URL for the RC channel. Defaults to the RC DMG for
    ///     `hostArchitecture`, since RC ships one DMG per architecture like nightly.
    ///   - hostArchitecture: The architecture whose nightly and RC DMGs are offered by default.
    public init(
        stableDownloadURLString: String = UpdateManualDownloadRecovery.stableDownloadURLString,
        nightlyDownloadURLString: String? = nil,
        rcDownloadURLString: String? = nil,
        hostArchitecture: UpdateHostArchitecture = .current
    ) {
        self.stableDownloadURLString = stableDownloadURLString
        self.nightlyDownloadURLString = nightlyDownloadURLString
            ?? Self.nightlyDownloadURLString(for: hostArchitecture)
        self.rcDownloadURLString = rcDownloadURLString
            ?? Self.rcDownloadURLString(for: hostArchitecture)
    }

    /// The cmux-next nightly download: cmux.com's redirect to the DMG of the update feed's
    /// newest item. A cmux-next build recovers to its own track, never to main's NIGHTLY DMG.
    ///
    /// Not the rolling `nightly-next` release asset: a later, best-effort job moves that name,
    /// so it can trail the feed by a build, and installing the build before the one the feed
    /// offers repeats the failed update. cmux-next ships for Apple silicon only, so the URL
    /// is the same on every Mac.
    public static let nightlyNextDownloadURLString = "https://cmux.com/api/download/next"

    /// The direct nightly DMG URL for `architecture`.
    public static func nightlyDownloadURLString(for architecture: UpdateHostArchitecture) -> String {
        "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-\(architecture.rawValue).dmg"
    }

    /// The direct RC DMG URL for `architecture`.
    public static func rcDownloadURLString(for architecture: UpdateHostArchitecture) -> String {
        "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-\(architecture.rawValue).dmg"
    }

    package func channelURL(feedURLString: String?) -> URL? {
        switch UpdateFeedResolver.Channel.classify(feedURL: feedURLString ?? "") {
        case .nightly:
            return URL(string: nightlyDownloadURLString)
        case .rc:
            return URL(string: rcDownloadURLString)
        case .nightlyNext:
            return URL(string: Self.nightlyNextDownloadURLString)
        case .stable:
            return URL(string: stableDownloadURLString)
        }
    }
}
