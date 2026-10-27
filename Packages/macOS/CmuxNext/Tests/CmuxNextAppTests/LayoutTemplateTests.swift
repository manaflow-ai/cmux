import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextWakeups
import Foundation
import Testing

/// Layout templates: Save Layout as Template (`saveLayoutTemplate`, Ctrl-Cmd-S, `workspace
/// save-layout-as-template --arg name=…`) keeps the workspace's screens, columns, splits and tabs
/// under a name; New Workspace from Template (`palette.layout.open`, `workspace new-from-template
/// --arg template=…`) builds a new workspace from one with new terminals; Manage Layout Templates
/// (`manageLayouts`) renames and deletes them. Templates are this Mac's, in an app-side file.
@MainActor @Suite(.serialized)
struct LayoutTemplateTests {
    static let ids: [ActionID] = ["saveLayoutTemplate", "palette.layout.open", "manageLayouts"]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    /// This Mac's daemon mirrors one workspace (`key`) whose pane holds a terminal; returns its id.
    static func workspace(_ services: AppServices, key: String = "ws-template", name: String = "api") throws -> String {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .pty)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: key), name: name, screens: [screen]),
        ]))
        return try #require(services.machines.local.store.workspaces.first).id
    }

    /// Runs `id` and waits for the work it tracked; returns the refusal, if any.
    @discardableResult
    static func run(_ services: AppServices, _ id: ActionID, _ invocation: ActionInvocation) async -> String? {
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { _ = services.registry.perform(id, invocation: invocation) }
        }
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        return refusal ?? failures.first
    }

    /// The template names New Workspace from Template offers.
    static func offered(_ services: AppServices) -> [String] {
        (services.registry.argumentSuggestions?("layoutTemplates") ?? []).map(\.value)
    }

    @Test func everyLayoutTemplateActionIsAvailable() {
        let services = Self.services()
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    /// A save from the CLI (`--arg name=`) keeps the target's layout under that name, and New
    /// Workspace from Template offers it; saving the same name again replaces it.
    @Test func savingALayoutOffersItAsATemplate() async throws {
        let services = Self.services()
        let workspace = try Self.workspace(services)
        let save = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace),
                                    arguments: ["name": .string("Two up")], origin: .cli)
        #expect(await Self.run(services, "saveLayoutTemplate", save) == nil)
        #expect(Self.offered(services) == ["Two up"])
        #expect(await Self.run(services, "saveLayoutTemplate", save) == nil)
        #expect(Self.offered(services) == ["Two up"], "a second save under one name replaces it")
    }

    /// A blank name and an unknown template refuse in words.
    @Test func aBlankNameAndAnUnknownTemplateRefuse() async throws {
        let services = Self.services()
        let workspace = try Self.workspace(services)
        let blank = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace),
                                     arguments: ["name": .string("  ")], origin: .cli)
        #expect(await Self.run(services, "saveLayoutTemplate", blank) == "A layout template needs a name")
        let unknown = ActionInvocation(arguments: ["template": .string("Nope")], origin: .cli)
        #expect(await Self.run(services, "palette.layout.open", unknown) == "No layout template named “Nope”")
        #expect(Self.offered(services).isEmpty)
    }

    // MARK: The repository and the library

    static let blueprint = WorkspaceBlueprint(name: "api", color: nil, icon: nil, screens: [
        WorkspaceBlueprint.Screen(name: nil, columns: [WorkspaceBlueprint.Column(width: nil, root: .split(
            direction: .right, ratio: 0.5, a: .pane([.terminal(cwd: "/tmp")]), b: .pane([.terminal(cwd: "/var")])))]),
    ])

    /// The file keeps every template across launches; a rename keeps the id, a name another
    /// template has (ignoring case) is refused, and a delete removes it from the file too.
    @Test func templatesPersistAndRenameAndDeleteThroughTheFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cn-layouts-\(UUID().uuidString.prefix(8))/layout-templates.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = LayoutTemplateLibrary(repository: LayoutTemplateRepository(fileURL: file), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try await library.save(name: "Two up", blueprint: Self.blueprint)
        try await library.save(name: "Solo", blueprint: Self.blueprint)
        let id = try #require(library.template(named: "two UP")?.id, "names match ignoring case")

        let relaunched = LayoutTemplateLibrary(repository: LayoutTemplateRepository(fileURL: file), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        await relaunched.load()
        #expect(relaunched.templates.map(\.name) == ["Two up", "Solo"])
        #expect(relaunched.template(named: "Two up")?.blueprint == Self.blueprint)

        try await relaunched.rename(id, to: "Side by side")
        #expect(relaunched.template(named: "Side by side")?.id == id)
        await #expect(throws: LayoutTemplateRepository.Failure.nameTaken) { try await relaunched.rename(id, to: "solo") }
        let solo = try #require(relaunched.template(named: "Solo")?.id)
        relaunched.deleteLater(solo)
        await relaunched.settled()
        #expect(relaunched.templates.map(\.name) == ["Side by side"])

        let again = LayoutTemplateLibrary(repository: LayoutTemplateRepository(fileURL: file), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        await again.load()
        #expect(again.templates.map(\.name) == ["Side by side"])
    }

    /// Manage Layout Templates lists one row per template (Return builds a workspace from it,
    /// Rename and Delete are its row's actions); with none it refuses in words.
    @Test func manageLayoutTemplatesListsEveryTemplate() async throws {
        let services = Self.services()
        let refusal = services.registry.capturingRefusal { _ = services.registry.perform("manageLayouts") }
        #expect(refusal == "No layout templates yet. Save a workspace’s layout as a template first.")
        try await services.layoutTemplates.save(name: "Two up", blueprint: Self.blueprint)
        let page = LayoutTemplateHandlers.managePage(services)
        var items: [PaletteItem] = []
        for provider in page.providers { items += await provider.items() }
        #expect(items.map(\.title) == ["Two up"])
        #expect(items.first?.subtitle == "Panes: 2")
        #expect(items.first?.secondary.map(\.id) == ["rename", "delete"])
    }
}

