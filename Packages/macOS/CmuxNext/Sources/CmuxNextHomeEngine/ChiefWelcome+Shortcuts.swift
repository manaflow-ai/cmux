public import CmuxNextActions

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

        /// The keys as Markdown: `` `⇧⌘P` ``, or `` `⌘J` then `S` `` for a chord.
        var markdown: String {
            guard let then else { return "`\(keys)`" }
            return HomeStrings.chiefWelcomeChord(keys, then)
        }
    }

    /// The shortcuts listed below the Go to Workspace call-out, in order.
    static let shortcutActions: [ActionID] = ["commandPalette", "search.chats", "newTab.default", "newSurface", "palette.newAgentChat"]
    /// Go to Workspace, normally ⌘P.
    static let goToAction: ActionID = "goToWorkspace"
    /// Start Agent from Any App, normally ⌃⌥⌘Space: the system-wide key, last in the list. Its setting
    /// (`app.startAgentGlobalHotKey`) is off until the person turns it on, so while it is off its line
    /// ends with a one-click link that turns it on (agent-shortcut-found).
    static let anyAppAction: ActionID = "palette.startAgentFromAnyApp"
    /// The link that turns Start Agent from Any App on (``DeepLink/settingsAction(for:linkScheme:)``).
    public static let anyAppLink = "cmux://settings" + DeepLink.startAgentFromAnyAppPath

    /// The welcome with `registry`'s current shortcuts; unbound actions are left out. `anyAppOn`:
    /// whether Start Agent from Any App's system-wide key is on now (no link to turn it on).
    @MainActor public static func text(_ registry: ActionRegistry, anyAppOn: Bool = false) -> String {
        let shortcut = { (id: ActionID) -> Shortcut? in
            guard let steps = registry.shortcutSteps(for: id), let keys = steps.first,
                  let title = registry.descriptor(for: id)?.title else { return nil }
            return Shortcut(keys: keys, then: steps.dropFirst().first, title: title.hasSuffix("…") ? String(title.dropLast()) : title)
        }
        return text(goTo: registry.shortcutDisplay(for: goToAction), shortcuts: shortcutActions.compactMap(shortcut),
                    anyApp: shortcut(anyAppAction), anyAppOn: anyAppOn)
    }

    /// The about message's Markdown: what Chief can do, Go to Workspace, other shortcuts and example requests.
    /// An unbound Go to Workspace (`goTo` nil) has no call-out. `anyApp` (Start Agent from Any App) ends the
    /// shortcut list, with a link that turns its key on unless `anyAppOn`.
    public nonisolated static func text(goTo: String?, shortcuts: [Shortcut], anyApp: Shortcut? = nil, anyAppOn: Bool = false) -> String {
        var blocks = [aboutText]
        if let goTo { blocks.append(HomeStrings.chiefWelcomeGoTo(goTo)) }
        var lines = shortcuts.map { "- \($0.markdown) \($0.title)" }
        if let anyApp {
            lines.append(anyAppOn ? "- \(anyApp.markdown) \(anyApp.title)" : "- " + HomeStrings.chiefWelcomeAnyApp(anyApp.markdown, anyApp.title, link: anyAppLink))
        }
        if !lines.isEmpty {
            blocks.append(([HomeStrings.chiefWelcomeShortcuts] + lines).joined(separator: "\n"))
        }
        blocks.append(HomeStrings.chiefWelcomeExamplesHeader + "\n" + HomeStrings.chiefWelcomeExamples)
        blocks.append(HomeStrings.chiefWelcomeAsk)
        return blocks.joined(separator: "\n\n")
    }
}
