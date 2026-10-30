import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextTerminal
import Testing

/// The App's side of the TextBox composer (inventory row 23): its actions are bound and
/// available, each TextBox control (``TextBoxCommand``) names a bound catalog action, and the
/// TextBox has its own key context. The composer itself is `TextBoxComposerTests` in
/// CmuxNextTerminalTests.
@MainActor @Suite(.serialized)
struct TextBoxActionTests {
    static let ids: [ActionID] = ["focusTextBoxInput", "palette.terminalToggleTextBoxInput", "cycleTextBoxSubmitAction",
                                  "attachTextBoxFile"]

    @Test func everyTextBoxActionIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    /// `TextBoxHandlers` runs a control as `ActionID(rawValue: command.rawValue)`: a renamed action
    /// would make the registry refuse silently (the Add Files button would do nothing).
    @Test(arguments: TextBoxCommand.allCases)
    func everyTextBoxControlNamesABoundAction(_ command: TextBoxCommand) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let id = ActionID(rawValue: command.rawValue)
        #expect(services.registry.descriptor(for: id)?.id == id, "\(command) names no catalog action")
        #expect(services.registry.isBound(id), "\(command) names an unbound action")
    }

    @Test func theTextBoxHasItsOwnKeyContext() {
        var focus = FocusState()
        focus.resolved = .textField
        let facts = KeyFacts(textBoxFocused: true)
        let context = KeyRouter.keyContext(for: focus, appContext: [.terminalFocused], facts: facts)
        #expect(context.bits.contains(.textBoxFocused))
        #expect(!context.bits.contains(.terminalFocused))
        let terminal = KeyRouter.keyContext(for: focus, appContext: [.textBoxFocused], facts: KeyFacts())
        #expect(!terminal.bits.contains(.textBoxFocused), "a stale app-wide textBoxFocused leaked into the key context")
    }
}
