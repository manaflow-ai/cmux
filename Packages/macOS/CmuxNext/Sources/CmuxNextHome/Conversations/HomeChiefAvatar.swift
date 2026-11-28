public import Foundation

/// The Chief's avatar as the app resolved it (Settings > the Chief's
/// profile, else the bundled default), for the Home list's Chief tile and
/// row to match the transcript header.
public nonisolated enum HomeChiefAvatar: Hashable, Sendable {
    /// A picture file on this Mac (profile.json's picture, or the bundled cat).
    case picture(URL)
    /// The profile's text avatar: one or two letters, or an emoji.
    case text(String)

    /// Letters and digits draw as a monogram, like the header's; anything
    /// else (an emoji, a flag, a symbol) draws on the grey disc. Characters
    /// are grapheme clusters, so a multi-scalar emoji is never split.
    var isMonogram: Bool {
        guard case .text(let text) = self else { return false }
        return !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
