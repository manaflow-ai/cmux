public import CmuxHomeRender
public import Foundation
public import Observation

/// Each Home chat's own bubble colours (Chat Colors…, `cmux chat colors`), kept on this Mac in
/// the app's defaults (`cmux.home.chatColors`, JSON by conversation id). A chat with none
/// draws the default for every chat (`home.bubbleColors.*`) over its bubble style.
@Observable @MainActor
public final class HomeChatColorStore {
    // UserDefaults is Apple-documented thread-safe; injected so tests use a suite of their own.
    @ObservationIgnored private let defaults: UserDefaults
    /// The chats with colours of their own, by conversation id.
    public private(set) var chats: [String: HomeBubbleColors]

    static let key = "cmux.home.chatColors"

    /// - Parameter defaults: where the colours are kept (the app's defaults; a suite in tests).
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        chats = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: HomeBubbleColors].self, from: $0) } ?? [:]
    }

    /// `conversation`'s own colours (empty when it has none).
    public func colors(for conversation: String) -> HomeBubbleColors { chats[conversation] ?? HomeBubbleColors() }

    /// Sets `conversation`'s own colours; empty colours remove them (Reset to Default).
    /// - Parameters:
    ///   - colors: the chat's colours.
    ///   - conversation: the conversation id.
    public func set(_ colors: HomeBubbleColors, for conversation: String) {
        guard self.colors(for: conversation) != colors else { return }
        if colors.isEmpty { chats[conversation] = nil } else { chats[conversation] = colors }
        if let data = try? JSONEncoder().encode(chats) { defaults.set(data, forKey: Self.key) }
    }

    /// Applies `home.chatColors` arguments (`cmux chat colors`, MCP) to `conversation`: each role
    /// given as `#RRGGBB`, or `default` (or `theme`) to clear it; `reset` clears every role first.
    /// - Parameters:
    ///   - values: the roles given (`sent`, `sentText`, `received`, `receivedText`), as typed.
    ///   - reset: clear the chat's colours first (Reset to Default).
    ///   - conversation: the conversation id.
    /// - Returns: false when nothing was given (a person's run then opens the panel).
    /// - Throws: ``HomeChatColorsRefusal`` for a value that is not a colour; nothing is changed then.
    @discardableResult
    public func apply(_ values: [String: String], reset: Bool, to conversation: String) throws(HomeChatColorsRefusal) -> Bool {
        var colors = reset ? HomeBubbleColors() : self.colors(for: conversation)
        var named = reset
        let roles: [(String, WritableKeyPath<HomeBubbleColors, HomeColor?>)] =
            [("sent", \.sent), ("sentText", \.sentText), ("received", \.received), ("receivedText", \.receivedText)]
        for (role, key) in roles {
            guard let text = values[role]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { continue }
            named = true
            if text == "default" || text == "theme" { colors[keyPath: key] = nil; continue }
            guard let color = HomeColor(hex: text) else { throw HomeChatColorsRefusal(role: role, value: text) }
            colors[keyPath: key] = color
        }
        guard named else { return false }
        set(colors, for: conversation)
        return true
    }

    /// The default for every chat from `home.bubbleColors.*` (`DesignSettings.homeBubbleColors`, `#RRGGBB` by role).
    /// - Parameter hexes: the roles' colours as cmux.json writes them.
    /// - Returns: the colours (a role with no colour stays nil).
    public nonisolated static func colors(fromHexes hexes: [String: String]) -> HomeBubbleColors {
        HomeBubbleColors(sent: hexes["sent"].flatMap(HomeColor.init(hex:)), sentText: hexes["sentText"].flatMap(HomeColor.init(hex:)),
                         received: hexes["received"].flatMap(HomeColor.init(hex:)),
                         receivedText: hexes["receivedText"].flatMap(HomeColor.init(hex:)))
    }
}
