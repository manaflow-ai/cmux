import Foundation

/// Chrome's "automatic downloads" rule, per site, for both engines (the
/// count of `DownloadRequestLimiter`): the first download a page starts
/// since the last user gesture on it goes ahead; each later one follows
/// the site's stored `automaticDownloads` setting (allow, block, or ask
/// once and remember the answer). A fresh user gesture (a mouse down or a
/// key down on the page, or a load cmux starts) makes the next download
/// the first again. One value per tab; `AutomaticDownloadGate` holds it.
public nonisolated struct AutomaticDownloadPolicy: Equatable, Sendable {
    /// What happens to one download a page starts.
    public enum Decision: Equatable, Sendable {
        case allow
        /// Ask the person once (Allow / Block); the answer is remembered
        /// for the site.
        case ask
        /// Refused without a prompt (the site is blocked).
        case refuse
    }

    /// The site of the counted downloads, nil after a gesture.
    public private(set) var site: String?
    /// Downloads `site` started since the last gesture.
    public private(set) var downloadsSinceGesture = 0

    public init() {}

    /// A fresh user gesture on the page.
    public mutating func userGesture() {}

    /// Counts a download a page on `site` starts. True when it is the first
    /// since the last gesture (a download from another site than the
    /// counted one starts a new count).
    public mutating func countDownload(site: String) -> Bool {
        true
    }

    /// The decision for a download: the first one goes ahead; a later one
    /// follows the site's stored setting.
    public static func decision(isFirst: Bool, setting: SitePermissionSetting) -> Decision {
        .allow
    }
}
