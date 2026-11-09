import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// #38631 review follow-ups: the palette asks for a new worktree's name and base and for Discard
/// Unsaved Work although they stay optional for the CLI and MCP, with leaving them as the first
/// answer; and a suggested list not read yet is awaited under the loading state, so the harness
/// icon pick never opens on an empty list that stays empty.
@MainActor
@Suite
struct PaletteAskedOptionalArgumentTests {
    private static func flow(_ id: ActionID, registry: ActionRegistry = .standard()) throws -> PaletteArgumentFlow {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
        return PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: nil)
    }

    private static func text(_ effect: PaletteEffect) throws -> PaletteTextInputSpec {
        var spec: PaletteTextInputSpec?
        if case .textInput(let input) = effect { spec = input }
        return try #require(spec, "not a text step")
    }

    private static func page(_ effect: PaletteEffect) throws -> PalettePageSpec {
        var spec: PalettePageSpec?
        if case .push(let page) = effect { spec = page }
        return try #require(spec, "not a list step")
    }

    @Test func newWorktreeAsksForItsNameThenItsBaseAndBothMayBeLeftEmpty() throws {
        let flow = try Self.flow("git.worktree.create")
        let name = try Self.text(flow.effect(collected: ActionInvocation()))
        #expect(name.isValid(""), "an empty name lets the session host pick one")
        #expect(name.placeholder == PaletteStrings.optionalArgument("Worktree Name"))
        let next = try #require(name.next)
        let base = try Self.text(next(""))
        #expect(base.isValid(""))
        let last = try #require(base.next)
        var runs = false
        if case .perform = last("") { runs = true }
        #expect(runs, "both left empty: the action runs, with no third step")
    }

    @Test func requiredTextStillRefusesEmpty() throws {
        let spec = try Self.text(Self.flow("renameWorkspace").effect(collected: ActionInvocation()))
        #expect(!spec.isValid(""))
    }

    @Test func removeWorktreeAsksDiscardAndOpensOnOff() async throws {
        let page = try Self.page(Self.flow("git.worktree.remove").effect(collected: ActionInvocation()))
        let items = await page.providers.first?.items() ?? []
        #expect(items.map(\.id) == ["option:false", "option:true"], "Return keeps unsaved work")
    }

    @Test func aListNotReadYetIsAwaitedNotShownEmpty() async throws {
        let registry = ActionRegistry.standard()
        registry.argumentSuggestions = { _ in [] }
        registry.argumentSuggestionsLoad = { source in
            guard source == ActionSuggestions.agentHarnessProfiles else { return nil }
            return { [ActionEnumCase(value: "acme", title: "Acme Agent")] }
        }
        let page = try Self.page(Self.flow("agent.harness.setIcon", registry: registry).effect(collected: ActionInvocation()))
        let provider = try #require(page.providers.first)
        #expect(provider.immediateItems == nil, "no empty list drawn before the answer: the palette shows its loading state")
        let items = await provider.items()
        #expect(items.contains { $0.id == "option:acme" })
    }

    @Test func aListAlreadyReadShowsAtOnce() async throws {
        let registry = ActionRegistry.standard()
        registry.argumentSuggestions = { _ in [ActionEnumCase(value: "acme", title: "Acme Agent")] }
        let page = try Self.page(Self.flow("agent.harness.setIcon", registry: registry).effect(collected: ActionInvocation()))
        let items = await page.providers.first?.items() ?? []
        #expect(items.contains { $0.id == "option:acme" })
    }

    @Test func askedOptionalArgumentsStayOptionalForScripts() throws {
        for id: ActionID in ["git.worktree.create", "git.worktree.remove"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            for argument in descriptor.arguments where argument.name != ActionArgument.confirmName {
                #expect(!argument.isRequired && argument.isAskedInPalette, "\(id).\(argument.name)")
            }
        }
    }
}
