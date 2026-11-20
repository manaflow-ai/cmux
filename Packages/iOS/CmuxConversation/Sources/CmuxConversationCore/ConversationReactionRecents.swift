import Foundation

/// The recent custom emoji tapbacks that Messages lists after the six classics
/// in the tapback bar: most recent first, then common defaults to fill the bar.
public struct ConversationReactionRecents {
    /// How many emoji the bar shows after the classics.
    public static let limit = 8
    /// Shown until enough emoji have been used (Messages seeds the bar from
    /// the emoji keyboard's Frequently Used, which starts with these).
    public static let defaults = ["\u{1F602}", "\u{2764}\u{FE0F}", "\u{1F525}", "\u{1F64F}", "\u{1F440}", "\u{1F389}", "\u{1F62E}", "\u{1F622}"]
    public static let defaultsKey = "conversation.reactionRecents"

    private let defaults: UserDefaults?
    private let key: String

    /// `defaults` nil keeps nothing (previews, tests that need the seed list).
    public init(defaults: UserDefaults? = .standard, key: String = Self.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Emoji actually used, most recent first.
    public var used: [String] {
        (defaults?.stringArray(forKey: key) ?? []).filter(ConversationReaction.isSingleEmoji)
    }

    /// What the bar shows after the classics: used emoji, then the defaults.
    public var emoji: [String] {
        var seen = Set<String>()
        return (used + Self.defaults).filter { seen.insert($0).inserted }.prefix(Self.limit).map { $0 }
    }

    /// Moves `reaction`'s emoji to the front. Classic tapbacks are not recents.
    public func record(_ reaction: ConversationReaction) {
        guard let emoji = reaction.emoji, let defaults else { return }
        let next = [emoji] + used.filter { $0 != emoji }
        defaults.set(Array(next.prefix(Self.limit)), forKey: key)
    }
}
