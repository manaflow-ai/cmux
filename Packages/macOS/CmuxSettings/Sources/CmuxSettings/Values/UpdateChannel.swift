import Foundation

/// Which Sparkle feed an install polls for updates.
///
/// Stored under the catalog entry ``UpdatesCatalogSection/channel``
/// (`updates.channel` in `~/.config/cmux/cmux.json`). The raw values are the
/// on-disk strings, so they must not be renamed without a migration.
///
/// Release-candidate and stable builds are the same app bits under the same
/// bundle identifier; the channel only decides which appcast the updater
/// queries. Nightly builds carry their own feed and ignore this setting.
public enum UpdateChannel: String, CaseIterable, Sendable, SettingCodable {
    /// The shipping release feed (default).
    case stable
    /// The release-candidate feed: the next stable build, a few days early.
    case rc
}
