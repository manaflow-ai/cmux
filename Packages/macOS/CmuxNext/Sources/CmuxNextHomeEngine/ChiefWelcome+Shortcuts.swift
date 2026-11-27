public import CmuxNextActions
internal import CmuxNextHomeModel

extension ChiefWelcome {
    /// One shortcut line, using the keys and title the action registry shows.
    public nonisolated struct Shortcut: Sendable, Equatable {
        /// The shortcut's display text, including any user rebind; a chord's first key.
        public var keys: String
        /// A chord's second key (`S` after `⌘J`), or nil for a single shortcut.
        public var then: String?
        /// The localized action title.
        public var title: String

        /// A shortcut with its displayed `keys`, a chord's second key `then`, and localized `title`.
        public init(keys: String, then: String? = nil, title: String) {
            self.keys = keys
            self.then = then
            self.title = title
        }
    }

    /// The welcome with `registry`'s current shortcuts; unbound actions are left out. `anyAppOn`:
    /// whether Start Agent from Any App's system-wide key is on now (no link to turn it on). The actions
    /// and their order are `welcome.shortcutActions`: the shortcuts people use every day (cmux#48416),
    /// then Start Agent from Any App, whose key is off until the person turns it on.
    @MainActor public static func text(_ registry: ActionRegistry, anyAppOn: Bool = false) -> String {
        let actions: ShortcutActions = welcomeRule("welcome.shortcutActions", HomeRules.Empty(),
                                                   fallback: ShortcutActions(actions: [], anyAppAction: nil))
        let shortcut = { (id: String) -> Shortcut? in
            let action = ActionID(rawValue: id)
            guard let steps = registry.shortcutSteps(for: action), let title = registry.descriptor(for: action)?.title else { return nil }
            let reply: ShortcutReply = welcomeRule("welcome.shortcut", ShortcutInput(steps: steps, title: title), fallback: ShortcutReply(shortcut: nil))
            return reply.shortcut.map { Shortcut(keys: $0.keys, then: $0.then, title: $0.title) }
        }
        return text(shortcuts: actions.actions.compactMap(shortcut), anyApp: actions.anyAppAction.flatMap(shortcut), anyAppOn: anyAppOn)
    }

    /// The about message's Markdown, kept short: one line on what Chief does, then how to use cmux (its shortcuts).
    /// `anyApp` (Start Agent from Any App) ends the shortcut list, with a link that turns its key on unless `anyAppOn`
    /// (`welcome.aboutText`).
    public nonisolated static func text(shortcuts: [Shortcut], anyApp: Shortcut? = nil, anyAppOn: Bool = false) -> String {
        let input = AboutInput(about: HomeStrings.chiefWelcomeAbout, shortcuts: shortcuts.map(WireShortcut.init), anyApp: anyApp.map(WireShortcut.init),
                               anyAppOn: anyAppOn, heading: HomeStrings.chiefWelcomeShortcuts,
                               chordFormat: HomeStrings.chiefWelcomeChordFormat, anyAppFormat: HomeStrings.chiefWelcomeAnyAppFormat)
        let reply: AboutReply = welcomeRule("welcome.aboutText", input, fallback: AboutReply(text: HomeStrings.chiefWelcomeAbout))
        return reply.text
    }
}

// The shortcut ops' wire shapes (cmux-home-rules `welcome/script.rs`).
private nonisolated struct ShortcutActions: Decodable {
    var actions: [String]
    var anyAppAction: String?
}

private nonisolated struct ShortcutInput: Encodable {
    var steps: [String]
    var title: String
}

private nonisolated struct ShortcutReply: Decodable {
    var shortcut: WireShortcut?
}

private nonisolated struct WireShortcut: Codable {
    var keys: String
    var then: String?
    var title: String

    init(_ shortcut: ChiefWelcome.Shortcut) {
        keys = shortcut.keys
        then = shortcut.then
        title = shortcut.title
    }
}

private nonisolated struct AboutInput: Encodable {
    var about: String
    var shortcuts: [WireShortcut]
    var anyApp: WireShortcut?
    var anyAppOn: Bool
    var heading: String
    var chordFormat: String
    var anyAppFormat: String
}

private nonisolated struct AboutReply: Decodable {
    var text: String
}
