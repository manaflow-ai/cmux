import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Typed rows for `palette.run` (palette-scopes.md 6.10): built-in rows
/// carry catalog ActionRefs, the run picks one by action id or takes the
/// primary, and a row without refs is refused.
@MainActor @Suite struct PaletteRunTests {
    let data = MockPaletteData()

    func controller() -> PaletteController {
        PaletteController(registry: ActionRegistry.standard(), sources: data.sources, frecencyPersistence: nil)
    }

    @Test func registryRowsRunTheirOwnAction() async throws {
        let ref = try await controller().runnableRef(scope: .commands, item: "action:renameTab", action: nil)
        #expect(ref.action == "renameTab")
        #expect(ref.target == nil)
        #expect(ref.title?.isEmpty == false)
    }

    @Test func tabRowsFocusFirstAndCloseByName() async throws {
        let palette = controller()
        let primary = try await palette.runnableRef(scope: .tabs, item: "tab:t2", action: nil)
        #expect(primary == PaletteActionRef("tab.focus", target: ActionTargetRef(kind: .tab, id: "t2"), title: primary.title))
        let close = try await palette.runnableRef(scope: .tabs, item: "tab:t2", action: "closeTab")
        #expect(close.action == "closeTab")
        #expect(close.target == ActionTargetRef(kind: .tab, id: "t2"))
        #expect(close.isDestructive)
    }

    @Test func workspaceRowsGoToTheirWorkspace() async throws {
        let ref = try await controller().runnableRef(scope: .workspaces, item: "workspace:w4", action: nil)
        #expect(ref.action == "goToWorkspace")
        #expect(ref.arguments["workspace"] == .target(ActionTargetRef(kind: .workspace, id: "w4")))
    }

    @Test func goToWorkspaceWithAWorkspaceSwitchesWithoutOpeningThePalette() {
        let palette = controller()
        palette.bindRegistryActions()
        let invocation = ActionInvocation(arguments: ["workspace": .target(ActionTargetRef(kind: .workspace, id: "w2"))], origin: .cli)
        #expect(palette.registry.perform("goToWorkspace", invocation: invocation))
        #expect(data.events == ["selectWorkspace:w2"])
        #expect(!palette.isVisible)
    }

    @Test func settingRowsToggleToTheOtherState() async throws {
        let ref = try await controller().runnableRef(scope: .settings, item: "setting:notifications.sound", action: nil)
        #expect(ref.action == "palette.toggleSetting")
        #expect(ref.arguments == ["setting": .string("notifications.sound"), "on": .bool(false)])
    }

    @Test func refusals() async {
        let palette = controller()
        await #expect(throws: PaletteRunSelection.Failure.unknownScope) {
            try await palette.runnableRef(scope: "nope", item: "x", action: nil)
        }
        await #expect(throws: PaletteRunSelection.Failure.refused(.unknownItem(scope: "tabs", item: "tab:none"))) {
            try await palette.runnableRef(scope: .tabs, item: "tab:none", action: nil)
        }
        await #expect(throws: PaletteRunSelection.Failure.refused(.unknownAction(item: "tab:t2", action: "renameTab"))) {
            try await palette.runnableRef(scope: .tabs, item: "tab:t2", action: "renameTab")
        }
        #expect(throws: PaletteRunRefusal.untyped(title: "Plain")) {
            try PaletteRunSelection.pick([], title: "Plain", item: "plain", action: nil)
        }
    }

    @Test func searchTabsRowsCarryFocusCloseAndReopen() {
        let source = MockTabSearchSource(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.reset(to: PalettePageSpec.tabSearch(source: source, style: .recent, now: { Date(timeIntervalSinceReferenceDate: 800_000_000) }))
        let open = model.rows.first { $0.id == "tab:tab_2" }?.item
        #expect(open?.actionRefs.map(\.action) == ["tab.focus", "closeTab"])
        #expect(open?.actionRefs.first?.target == ActionTargetRef(kind: .tab, id: "tab_2"))
        let closed = model.rows.first { $0.id == "closed:local/tab_8" }?.item
        #expect(closed?.actionRefs.map(\.action) == ["history.reopen"])
        #expect(closed?.actionRefs.first?.arguments == ["id": .string("local/tab_8")])
    }
}
