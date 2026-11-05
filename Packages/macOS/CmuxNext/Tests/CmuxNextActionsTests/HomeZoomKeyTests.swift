import AppKit
import CmuxNextActions
import Testing

/// Cmd-= (and Cmd-+), Cmd-- and Cmd-0 on Home zoom the Chief chat (`home.zoomIn`, `home.zoomOut`,
/// `home.zoomReset`); elsewhere the keys keep their owner (an agent chat's zoom, a terminal's font
/// size). The binding table resolves each key in the contexts the key router builds.
@MainActor @Suite struct HomeZoomKeyTests {
    static let keys: [(Shortcut, String)] = [
        (Shortcut("=", modifiers: [.command]), "home.zoomIn"),
        (Shortcut("=", modifiers: [.command, .shift]), "home.zoomIn"),
        (Shortcut("-", modifiers: [.command]), "home.zoomOut"),
        (Shortcut("0", modifiers: [.command]), "home.zoomReset"),
    ]

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return registry
    }

    static func winner(_ key: Shortcut, in context: KeyContext, registry: ActionRegistry? = nil) -> String? {
        let table = RegistryKeyBindings(registry ?? Self.registry()).table
        return table.resolve([key], in: context, isRunnable: { _ in true }).winner?.command.rawValue
    }

    @Test(arguments: [
        [KeyContext.topPage: KeyContextValue.string("home")],
        [KeyContext.surfaceKind: .string("home")],
        [KeyContext.surfaceKind: .string("home-dock")],
    ])
    func zoomKeysZoomTheChiefChatOnHome(context: [String: KeyContextValue]) {
        for (key, command) in Self.keys {
            #expect(Self.winner(key, in: KeyContext(context)) == command, "\(key) on \(context)")
        }
    }

    @Test func zoomKeysStayWithTheAgentChatAndTheTerminal() {
        var agent = KeyContext(bits: [.agentPaneFocused])
        agent[KeyContext.surfaceKind] = .string("agent")
        #expect(Self.winner(Shortcut("=", modifiers: [.command]), in: agent) == "agentPaneZoomIn")
        #expect(Self.winner(Shortcut("-", modifiers: [.command]), in: agent) == "agentPaneZoomOut")
        #expect(Self.winner(Shortcut("0", modifiers: [.command]), in: agent) == "agentPaneZoomReset")
        var terminal = KeyContext(bits: [.terminalFocused])
        terminal[KeyContext.surfaceKind] = .string("terminal")
        for (key, _) in Self.keys {
            #expect(Self.winner(key, in: terminal)?.hasPrefix("home.") != true, "\(key) in a terminal")
        }
    }

    /// A rebind in Settings or cmux.json keeps the Home scope: it never zooms the Chief chat from a terminal.
    @Test func aReboundChiefZoomKeyStaysOnHome() {
        let registry = Self.registry()
        let key = Shortcut("k", modifiers: [.control, .option])
        registry.setShortcutOverride(key, for: "home.zoomIn")
        #expect(Self.winner(key, in: KeyContext([KeyContext.topPage: .string("home")]), registry: registry) == "home.zoomIn")
        var terminal = KeyContext(bits: [.terminalFocused])
        terminal[KeyContext.surfaceKind] = .string("terminal")
        #expect(Self.winner(key, in: terminal, registry: registry) != "home.zoomIn")
    }
}
