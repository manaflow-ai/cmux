import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// An argument list step marks the value in effect and opens on it, and an optional argument the
/// handler asks for (a menu Rename with no name) becomes a text step that starts from the current
/// text, all inside Cmd-Shift-P.
@MainActor
@Suite
struct PaletteArgumentCurrentValueTests {
    private static func descriptor(_ id: ActionID) throws -> ActionDescriptor {
        try #require(ActionCatalog.all.first { $0.id == id })
    }

    @Test func teamStepMarksAndSelectsTheCurrentTeam() throws {
        let registry = ActionRegistry.standard()
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.cloudTeams
                ? [ActionEnumCase(value: "team_1", title: "Manaflow", subtitle: "Team · Team plan", symbol: "person.2"),
                   ActionEnumCase(value: "team_2", title: "Personal", subtitle: "leo@example.com", symbol: "person")] : []
        }
        registry.choiceState = { id, _ in id == "openTeamPicker" ? "team_2" : nil }
        let flow = PaletteArgumentFlow(registry: registry, descriptor: try Self.descriptor("openTeamPicker"), targets: nil)

        var page: PalettePageSpec?
        if case .push(let pushed) = flow.effect(collected: ActionInvocation()) { page = pushed }
        let step = try #require(page, "Team Picker does not list teams inline")
        let items = try #require(step.providers.first as? StaticPaletteProvider).itemsList
        #expect(items.map(\.title) == ["Manaflow", "Personal"])
        // One checkmark, on the active team, never a bare "Current" (Leo, 2026-11-09: "what is this?").
        #expect(items.filter { $0.accessory == PaletteStrings.chosenMark }.map(\.id) == ["option:team_2"])
        #expect(!items.contains { $0.accessory == PaletteStrings.current })
        // The person's own team reads as Personal with a person icon; a shared team with people.
        #expect(items.map(\.symbol) == ["person.2", "person"])
        // Every row has its second line when the data has one.
        #expect(items.map(\.subtitle) == ["Team · Team plan", "leo@example.com"])
        #expect(step.emptyQuerySelectionID == "option:team_2")
    }

    @Test func anAskedOptionalArgumentBecomesATextStep() throws {
        let flow = PaletteArgumentFlow(registry: ActionRegistry.standard(), descriptor: try Self.descriptor("renamePane"), targets: nil,
                                       ask: ActionArgumentAsk(argument: "name", initialText: "api"))
        var spec: PaletteTextInputSpec?
        if case .textInput(let input) = flow.effect(collected: ActionInvocation()) { spec = input }
        let step = try #require(spec, "Rename Pane does not ask for the name inline")
        #expect(step.initialText == "api")
        #expect(step.skipsUnchangedText)
    }
}
