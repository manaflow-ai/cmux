import AppKit
import CmuxNextActions
import Testing

/// Cmd-Shift-R on Home is Reply to Selection (plans/cmux-next/reply-to-selection-DESIGN.md);
/// elsewhere the key is not taken by it. The binding table resolves the key in each context the
/// key router builds.
@MainActor @Suite struct HomeReplyToSelectionKeyTests {
    static let cmdShiftR = [Shortcut("r", modifiers: [.command, .shift])]

    @Test(arguments: [
        ([KeyContext.topPage: KeyContextValue.string("home")], true),
        ([KeyContext.surfaceKind: .string("home")], true),
        ([KeyContext.surfaceKind: .string("home-dock")], true),
        ([KeyContext.surfaceKind: .string("terminal")], false),
        ([KeyContext.surfaceKind: .string("page")], false),
    ])
    func cmdShiftRIsReplyToSelectionOnHomeOnly(context: [String: KeyContextValue], onHome: Bool) {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        let table = RegistryKeyBindings(registry).table
        let winner = table.resolve(Self.cmdShiftR, in: KeyContext(context), isRunnable: { _ in true }).winner
        #expect((winner?.command.rawValue == "home.replyToSelection") == onHome)
    }
}
