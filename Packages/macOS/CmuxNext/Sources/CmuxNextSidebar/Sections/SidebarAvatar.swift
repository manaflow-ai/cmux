public import Foundation

/// A person drawn as a round picture, or their initials on a round fill
/// while there is no picture (the footer's signed-in user).
public nonisolated struct SidebarAvatar: Hashable, Sendable {
    public var initials: String
    /// Encoded image data (PNG, JPEG); nil draws the initials.
    public var imageData: Data?

    public init(name: String, imageData: Data? = nil) {
        initials = Self.initials(for: name)
        self.imageData = imageData
    }

    /// The first letters of the first and last words ("Leo Li" is "LL"), the
    /// first letter of a single word or an email's local part, else "?".
    public static func initials(for name: String) -> String {
        let local = name.contains("@") ? String(name.prefix { $0 != "@" }) : name
        let words = local.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first)
        guard let first = words.first else { return "?" }
        let letters = words.count > 1 ? [first, words[words.count - 1]] : [first]
        return String(letters).uppercased()
    }
}
