import AppKit
import CmuxNextActions
import Testing

/// Cmd-N on Home is Messages' New Message (Lawrence 2026-10-19); everywhere else it stays New
/// Workspace. The binding table resolves the key in each context the key router builds.
@MainActor @Suite struct HomeNewMessageKeyTests {
    static let cmdN = [Shortcut("n", modifiers: [.command])]

    @Test(arguments: [
        ([KeyContext.topPage: KeyContextValue.string("home")], "home.newMessage"),
        ([KeyContext.surfaceKind: .string("home")], "home.newMessage"),
        ([KeyContext.surfaceKind: .string("home-dock")], "home.newMessage"),
        ([KeyContext.surfaceKind: .string("terminal")], "newTab"),
        ([KeyContext.surfaceKind: .string("page")], "newTab"),
        ([:], "newTab"),
    ])
    func cmdNIsNewMessageOnHomeOnly(context: [String: KeyContextValue], action: String) {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        let table = RegistryKeyBindings(registry).table
        let winner = table.resolve(Self.cmdN, in: KeyContext(context), isRunnable: { _ in true }).winner
        #expect(winner?.command.rawValue == action)
    }

    @Test func aRemappedNewMessageLeavesCmdNToNewWorkspaceOnHome() {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.setShortcutOverride(Shortcut("m", modifiers: [.command, .shift]), for: "home.newMessage")
        let table = RegistryKeyBindings(registry).table
        let home = KeyContext([KeyContext.topPage: .string("home")])
        #expect(table.resolve(Self.cmdN, in: home, isRunnable: { _ in true }).winner?.command.rawValue == "newTab")
    }
}
