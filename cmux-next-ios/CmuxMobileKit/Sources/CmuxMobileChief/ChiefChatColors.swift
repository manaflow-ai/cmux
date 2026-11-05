import CmuxConversationCore
import Foundation
import Observation

/// Chat Colors (the Mac's `home.chatColors`): each chat's own bubble colours, kept on this phone
/// by Mac and conversation (the Mac keeps its own on the Mac). A chat with none draws Messages'
/// colours.
@MainActor
@Observable
public final class ChiefChatColors {
    public static let shared = ChiefChatColors()
    static let defaultsKey = "cmux.chief.chatColors.v1"

    private(set) var chats: [String: ConversationBubbleColors]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chats = Self.decode(defaults.data(forKey: Self.defaultsKey))
    }

    /// Each chat read on its own: one entry this build cannot read never drops the others.
    static func decode(_ data: Data?) -> [String: ConversationBubbleColors] {
        guard let data, let entries = try? JSONDecoder().decode([String: Lenient].self, from: data) else { return [:] }
        return entries.compactMapValues(\.colors)
    }

    private struct Lenient: Decodable {
        let colors: ConversationBubbleColors?
        init(from decoder: any Decoder) throws { colors = try? ConversationBubbleColors(from: decoder) }
    }

    /// The key of one chat: its Mac (or the Cloud) and its conversation.
    static func key(macID: String?, conversation: String) -> String { "\(macID ?? "cloud")|\(conversation)" }

    /// `key`'s own colours (empty when it has none).
    public func colors(for key: String) -> ConversationBubbleColors { chats[key] ?? ConversationBubbleColors() }

    /// Sets `key`'s colours; empty colours remove them (Reset to Default).
    public func set(_ colors: ConversationBubbleColors, for key: String) {
        guard self.colors(for: key) != colors else { return }
        chats[key] = colors.isEmpty ? nil : colors
        if let data = try? JSONEncoder().encode(chats) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Changes one role of `key`'s colours.
    public func update(_ key: String, _ change: (inout ConversationBubbleColors) -> Void) {
        var colors = colors(for: key)
        change(&colors)
        set(colors, for: key)
    }
}
