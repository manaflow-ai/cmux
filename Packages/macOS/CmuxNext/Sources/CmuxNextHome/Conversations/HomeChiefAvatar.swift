public import Foundation

/// The Chief's avatar as the app resolved it (Settings > the Chief's
/// profile, else ``chiefDefault``), for the Home list's Chief tile and
/// row to match the transcript header.
public nonisolated enum HomeChiefAvatar: Hashable, Sendable, Codable {
    /// A picture file on this Mac (profile.json's picture).
    case picture(URL)
    /// The profile's text avatar: one or two letters, or an emoji.
    case text(String)

    /// The text a Chief with no avatar of its own shows: the saluting face.
    public static let defaultText = "🫡"
    /// The avatar a Chief with no avatar of its own shows (drawn as text, so
    /// it is sharp at every size and in light and dark).
    public static let chiefDefault = HomeChiefAvatar.text(defaultText)

    /// The Chief's own avatar, else ``chiefDefault``.
    /// - Parameter own: The avatar the Chief's profile sets, or nil for none.
    public static func resolved(_ own: HomeChiefAvatar?) -> HomeChiefAvatar { own ?? chiefDefault }

    /// The header's avatar: the Chief's own picture or text, else the
    /// default text (no picture).
    /// - Parameters:
    ///   - text: The profile's text avatar, or nil.
    ///   - hasPicture: Whether the profile's picture was read.
    /// - Returns: The text to draw when no picture shows.
    public static func headerText(_ text: String?, hasPicture: Bool) -> String? {
        text ?? (hasPicture ? nil : defaultText)
    }

    /// Letters and digits draw as a monogram, like the header's; anything
    /// else (an emoji, a flag, a symbol) draws on the grey disc. Characters
    /// are grapheme clusters, so a multi-scalar emoji is never split.
    var isMonogram: Bool {
        guard case .text(let text) = self else { return false }
        return !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
