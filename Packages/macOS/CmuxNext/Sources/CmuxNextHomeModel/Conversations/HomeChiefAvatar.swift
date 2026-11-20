public import Foundation

/// The Chief's avatar as the app resolved it (Settings > the Chief's
/// profile, else ``chiefDefault``, its monogram), for the Home list's Chief tile and
/// row to match the transcript header.
public nonisolated enum HomeChiefAvatar: Hashable, Sendable, Codable {
    /// A picture file on this Mac (profile.json's picture).
    case picture(URL)
    /// The profile's text avatar: one or two letters, or an emoji.
    case text(String)

    /// The text the default Chief ("Chief") shows with no avatar of its own: its iMessage-style
    /// monogram (Lawrence 2026-10-30: "just maybe CH for chief? like in imessage. no profile pic by
    /// default"), never a pet character or 🫡.
    public static let defaultText = "CH"
    /// The avatar the default Chief shows with no avatar of its own: its monogram (drawn as text, so
    /// it is sharp at every size and in light and dark).
    public static let chiefDefault = HomeChiefAvatar.text(defaultText)

    /// The Chief's own avatar, else ``chiefDefault``.
    /// - Parameter own: The avatar the Chief's profile sets, or nil for none.
    public static func resolved(_ own: HomeChiefAvatar?) -> HomeChiefAvatar { own ?? chiefDefault }
}
