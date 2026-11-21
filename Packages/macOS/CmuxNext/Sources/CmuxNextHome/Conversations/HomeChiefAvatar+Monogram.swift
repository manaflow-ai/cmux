public import CmuxNextHomeModel
import MessagesLabHome

/// The monogram parts of ``HomeChiefAvatar`` the Home views draw with (MessagesLab's ``MonogramAvatar``).
nonisolated extension HomeChiefAvatar {
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
