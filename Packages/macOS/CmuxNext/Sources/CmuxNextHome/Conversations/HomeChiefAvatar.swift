public import Foundation
import MessagesLabHome

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

    /// The monogram letters of a Chief named `name` (`MonogramAvatar`: "Chief" is CH, "Scout Two"
    /// is ST); the default Chief's ``defaultText`` for an empty name.
    /// - Parameter name: The Chief's shown name.
    /// - Returns: One or two uppercased letters or digits.
    public static func monogram(of name: String) -> String {
        name.isEmpty ? defaultText : MonogramAvatar(name: name).initials
    }

    /// Letters and digits draw as a monogram, like the header's; anything
    /// else (an emoji, a flag, a symbol) draws on the grey disc. Characters
    /// are grapheme clusters, so a multi-scalar emoji is never split.
    var isMonogram: Bool {
        guard case .text(let text) = self else { return false }
        return !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
