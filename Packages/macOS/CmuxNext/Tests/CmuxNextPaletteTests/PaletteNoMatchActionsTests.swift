import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// A typed query that matches nothing offers what to do with the words instead of "No Results":
/// a browser profile picker makes the profile by that name and runs the action on it, and
/// Cmd-Shift-P and Cmd-P ask an agent, search the web, or make a workspace. Return runs the
/// first row.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteNoMatchActionsTests {
    private final class Profiles: PaletteTargetSource {
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
            guard kind == .browserProfile else { return [] }
            return [PaletteTargetOption(id: "default", title: "Default"), PaletteTargetOption(id: "p-work", title: "Work")]
        }
    }

    private final class Log {
        var created: [String] = []
        var runs: [ActionInvocation] = []
        var prompts: [String] = []
        var searches: [String] = []
    }

    private final class GoTo: PaletteGoToSource {
        let log: Log
        init(_ log: Log) { self.log = log }
        func baseDirectory() -> String? { nil }
        func open(_ target: PaletteQueryTarget) {}
        func askAgent(about target: PaletteQueryTarget, prompt: String?) {}
        func askAgent(prompt: String) { log.prompts.append(prompt) }
    }

    private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "w1", title: "api server", directory: nil, isSelected: false)]
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    /// Yields to the main actor until `done`, at most 10,000 times (false then, instead of hanging).
    private static func yield(until done: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if done() { return true }
            await Task.yield()
        }
        return done()
    }

    private static func creator(_ log: Log) -> PaletteTargetCreator {
        PaletteTargetCreator(title: { "Create Browser Profile “\($0)”" }, symbol: "person.crop.circle.badge.plus") { name in
            log.created.append(name)
            return "p-\(name)"
        }
    }

    private static func profileStep(_ action: ActionID, registry: ActionRegistry, log: Log) throws -> PalettePageSpec {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == action })
        let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: Profiles(),
                                       creators: [.browserProfile: creator(log)])
        guard case .push(let page) = flow.effect(collected: ActionInvocation()) else {
            Issue.record("\(action) does not list browser profiles inline")
            throw CancellationError()
        }
        return page
    }

    private static func palette(_ registry: ActionRegistry = .standard(), sources: PaletteSources = PaletteSources()) -> PaletteController {
        _ = NSApplication.shared
        return PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
    }

    private static func ids(_ palette: PaletteController, after query: String) async -> [String] {
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        return palette.model.rows.map(\.item.id)
    }

    // MARK: Browser profile pickers

    @Test func anUnknownProfileNameIsCreatedAndTheTabOpensInIt() async throws {
        let log = Log()
        let registry = ActionRegistry.standard()
        registry.bind("browserProfile.newTab", invoke: { log.runs.append($0) })
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        palette.model.reset(to: try Self.profileStep("browserProfile.newTab", registry: registry, log: log))
        await palette.model.settle()

        #expect(await Self.ids(palette, after: "austin ") == ["create:browser-profile"])
        #expect(palette.model.rows.first?.item.title == "Create Browser Profile “austin”")
        #expect(palette.model.selectedRowID == "create:browser-profile", "Return runs the create row")

        _ = palette.model.handle(.submit)
        #expect(await Self.yield { !log.runs.isEmpty })
        #expect(log.created == ["austin"])
        let profile = try #require(log.runs.first?["browserProfile"])
        #expect((profile.targetValue?.id ?? profile.stringValue) == "p-austin")
    }

    @Test func aMatchingProfileListsItAndOffersNoCreate() async throws {
        let log = Log()
        let registry = ActionRegistry.standard()
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        palette.model.reset(to: try Self.profileStep("browserProfile.newTab", registry: registry, log: log))
        await palette.model.settle()
        #expect(await Self.ids(palette, after: "wor") == ["option:p-work"])
    }

    @Test func everyProfilePickerThatRunsOnThePickOffersCreate() throws {
        // Open Link in Browser Profile… takes the link as an optional argument: a pick runs the action at once,
        // so making the profile first and then running it is the same path.
        let page = try Self.profileStep("browserProfile.openLink", registry: .standard(), log: Log())
        let rows = try #require(page.noMatchItems)
        #expect(rows("austin").map(\.id) == ["create:browser-profile"])
        #expect(rows("  ").isEmpty)
    }

    // MARK: Cmd-Shift-P and Cmd-P

    @Test func commandPaletteOffersAgentSearchAndWorkspaceForUnmatchedWords() async {
        let log = Log()
        let registry = ActionRegistry.standard()
        registry.bind("newTab", invoke: { log.runs.append($0) })
        registry.bind("browser.selection.search", invoke: { log.searches.append($0["text"]?.stringValue ?? "") })
        var sources = PaletteSources()
        sources.goTo = GoTo(log)
        let palette = Self.palette(registry, sources: sources)
        defer { palette.closeForTest() }
        palette.show(.commands)
        let query = "qzxjvkw wq"
        #expect(await Self.ids(palette, after: query) == ["noMatch:askAgent", "noMatch:searchWeb", "noMatch:newWorkspace", "noMatch:runCommand"])
        #expect(palette.model.rows.map(\.item.title) == [
            PaletteStrings.noMatchAskAgent(query), PaletteStrings.noMatchSearchWeb(query),
            PaletteStrings.noMatchNewWorkspace(query), PaletteStrings.noMatchRunCommand(query),
        ])
        _ = palette.model.handle(.submit)
        #expect(log.prompts == [query])
    }

    @Test func eachCommandPaletteRowRunsItsPath() async {
        let log = Log()
        let registry = ActionRegistry.standard()
        registry.bind("newTab", invoke: { log.runs.append($0) })
        registry.bind("browser.selection.search", invoke: { log.searches.append($0["text"]?.stringValue ?? "") })
        var sources = PaletteSources()
        sources.goTo = GoTo(log)
        let palette = Self.palette(registry, sources: sources)
        defer { palette.closeForTest() }
        for row in ["noMatch:searchWeb", "noMatch:newWorkspace", "noMatch:runCommand"] {
            palette.show(.commands)
            _ = await Self.ids(palette, after: "qzxjvkw")
            palette.model.activate(rowID: row)
        }
        #expect(log.searches == ["qzxjvkw"])
        #expect(log.runs.map { $0["name"]?.stringValue } == ["qzxjvkw", nil])
        #expect(log.runs.map { $0["command"]?.stringValue } == [nil, "qzxjvkw"])
    }

    @Test func goToWorkspaceOffersANewWorkspaceByThatName() async {
        let log = Log()
        let registry = ActionRegistry.standard()
        registry.bind("newTab", invoke: { log.runs.append($0) })
        var sources = PaletteSources(workspaces: Workspaces())
        sources.goTo = GoTo(log)
        let palette = Self.palette(registry, sources: sources)
        defer { palette.closeForTest() }
        palette.show(.workspaces)
        #expect(await Self.ids(palette, after: "qzxjvkw") == ["noMatch:newWorkspace", "noMatch:askAgent"])
        _ = palette.model.handle(.submit)
        #expect(log.runs.first?["name"]?.stringValue == "qzxjvkw")
    }

    @Test func aMatchingQueryListsItsResultsFirstAndTheFallbacksAfter() async {
        let registry = ActionRegistry.standard()
        registry.bind("newTab", invoke: { _ in })
        var sources = PaletteSources(workspaces: Workspaces())
        sources.goTo = GoTo(Log())
        let palette = Self.palette(registry, sources: sources)
        defer { palette.closeForTest() }
        palette.show(.workspaces)
        let ids = await Self.ids(palette, after: "api")
        #expect(ids.first == "workspace:w1", "Return opens the match: \(ids)")
        #expect(Array(ids.suffix(2)) == ["noMatch:newWorkspace", "noMatch:askAgent"], "\(ids)")
    }
}
