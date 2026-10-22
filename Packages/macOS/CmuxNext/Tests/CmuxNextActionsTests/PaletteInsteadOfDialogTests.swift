import CmuxNextActions
import Testing

/// Pickers and one-line prompts ask inside Cmd-Shift-P, never in a separate dialog
/// (Lawrence 2026-10-20: "the team picker should be integrated, not a separate dialog").
@MainActor
@Suite
struct PaletteInsteadOfDialogTests {
    @Test func teamPickerWithoutATeamAsksInThePalette() {
        let registry = ActionRegistry.standard()
        var ran: [ActionInvocation] = []
        var collected: [ActionID] = []
        registry.bind("openTeamPicker", invoke: { ran.append($0) })
        registry.argumentCollector = { id, _ in collected.append(id) }

        #expect(registry.perform("openTeamPicker"))
        #expect(ran.isEmpty)
        #expect(collected == ["openTeamPicker"])

        #expect(registry.perform("openTeamPicker", invocation: ActionInvocation(arguments: ["team": .string("team_2")])))
        #expect(ran.first?["team"] == .string("team_2"))
    }

    @Test func askSendsAnOptionalArgumentToThePalette() {
        let registry = ActionRegistry.standard()
        var asked: [(ActionID, ActionInvocation, ActionArgumentAsk)] = []
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: "p1"))

        #expect(!registry.ask("renamePane", invocation, ActionArgumentAsk(argument: "name", initialText: "api")))

        registry.argumentAsker = { asked.append(($0, $1, $2)) }
        #expect(registry.ask("renamePane", invocation, ActionArgumentAsk(argument: "name", initialText: "api")))
        #expect(asked.first?.0 == "renamePane")
        #expect(asked.first?.1.target == invocation.target)
        #expect(asked.first?.2 == ActionArgumentAsk(argument: "name", initialText: "api"))
    }
}
