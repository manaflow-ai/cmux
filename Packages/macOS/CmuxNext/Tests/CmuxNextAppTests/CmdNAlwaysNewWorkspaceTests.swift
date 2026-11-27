import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Cmd-N makes a new workspace wherever the keyboard is. Lawrence 2026-10-20: "I just did Command
/// and when I focused on Home it didn't make a new workspace. Command + N needs to always make a new
/// workspace." Before: a Home-only binding (2026-10-19) sent Cmd-N to New Message in the Home chat,
/// the Home list, its composer and the docked Home chat.
@MainActor @Suite struct CmdNAlwaysNewWorkspaceTests {
    /// The router holds the registry `unowned`; the suite keeps it.
    let registry: ActionRegistry
    let ran: Ran

    /// The actions that ran, in order.
    @MainActor final class Ran { var ids: [String] = [] }

    init() {
        let registry = ActionRegistry.standard()
        let ran = Ran()
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id) { ran.ids.append(id.rawValue) }
        }
        self.registry = registry
        self.ran = ran
    }

    static func cmdN() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1, windowNumber: 0,
                                      context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
    }

    /// Every place the keyboard can be in a main window, Home first.
    nonisolated static let kinds: [String] = [
        "home list", "home composer", "home dock", "home conversation pane", "terminal", "browser page", "address bar",
        "find bar", "agent chat", "markdown viewer", "code editor", "settings page", "empty pane", "sidebar",
    ]

    static func focusAndFacts(_ kind: String) -> (FocusState, KeyFacts) {
        var focus = FocusState()
        var facts = KeyFacts()
        switch kind {
        case "home list":
            focus.resolved = .conversation(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(listFocus: true, topPage: "home")
        case "home composer":
            focus.resolved = .conversation(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageEditableFocused: true, topPage: "home")
        case "home dock":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageEditableFocused: true, internalPage: "home-dock")
        case "home conversation pane":
            focus.resolved = .conversation(pane: "pane_a", tab: "tab_a")
        case "terminal":
            focus.resolved = .terminal(pane: "pane_a", tab: "tab_a")
            focus.context.terminal = true
        case "browser page":
            focus.resolved = .browserPage(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "address bar":
            focus.resolved = .addressBar(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "find bar":
            focus.resolved = .findBar(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "agent chat":
            focus.resolved = .agentPage(pane: "pane_a", tab: "tab_a")
            focus.context.agent = true
        case "markdown viewer":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: KeyRouter.markdownPageID, pageEditableFocused: true)
        case "code editor":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: KeyRouter.codeEditorPageID, pageEditableFocused: true)
        case "settings page":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: "cmux.settings", pageEditableFocused: true)
        case "empty pane":
            focus.resolved = .emptyPane(pane: "pane_a")
        default:
            focus.resolved = .sidebar
        }
        return (focus, facts)
    }

    /// The key router decides Cmd-N as New Workspace (`newTab`, the classic id) in every place.
    @Test(arguments: kinds)
    func cmdNIsNewWorkspaceEverywhere(_ kind: String) throws {
        let (focus, facts) = Self.focusAndFacts(kind)
        let decision = KeyRouter(registry: registry).decide(try Self.cmdN(), focus: focus, keyWindow: .content, facts: facts)
        guard case .run(let candidate) = decision else {
            Issue.record("Cmd-N in the \(kind) ran nothing: \(decision)")
            return
        }
        #expect(candidate.id.rawValue == "newTab", "Cmd-N in the \(kind): \(decision)")
    }

    /// The binding table has no Home-scoped Cmd-N: New Message keeps its button, palette and menu.
    @Test func noScopedDefaultTakesCmdN() {
        let cmdN = [Shortcut("n", modifiers: [.command])]
        #expect(!KeyBindingDefaults.scopedDefaults.contains { $0.keys == cmdN })
        let table = RegistryKeyBindings(registry).table
        for context in [KeyContext([KeyContext.topPage: .string("home")]), KeyContext([KeyContext.surfaceKind: .string("home")]),
                        KeyContext([KeyContext.surfaceKind: .string("home-dock")])] {
            #expect(table.resolve(cmdN, in: context, isRunnable: { _ in true }).winner?.command.rawValue == "newTab")
        }
    }
}
