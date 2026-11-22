import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextPalette
import CmuxNextSidebar
import Testing

/// The App's palette target chain after rename prompts started from the
/// current name (#16906 review): naming a rename's target must not change
/// what other pickers list, and a fallback title is never offered as a name.
@MainActor @Suite(.serialized) struct RenamePrefillTargetTests {
    /// A `next` source that answers every kind with one marker option.
    final class MarkerSource: PaletteTargetSource {
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
            [PaletteTargetOption(id: "marker", title: "from next")]
        }
    }

    /// Reopen Saved Tab Group…, Delete Saved Tab Group… and Add Tab to
    /// Group… pick a `.tabGroup`; Go to Tab… picks a `.tab`; Move Workspace
    /// to Group… picks a `.workspaceGroup`. Their lists come
    /// from further down the chain, as before tabs and tab groups had names
    /// to offer: open groups (or other machines' groups) listed there are
    /// refused by those actions.
    @Test(arguments: [ActionTargetKind.tab, .tabGroup, .workspaceGroup])
    func tabPickersKeepTheirLists(_ kind: ActionTargetKind) {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let source = TabAndGroupTargetSource(services: services, next: MarkerSource())
        #expect(source.targets(of: kind).map(\.id) == ["marker"])
    }

    /// The untitled Workspaces section shows a fallback label; Rename
    /// Section… starts empty instead of offering that label as its name.
    @Test func anUntitledSectionStartsEmpty() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = ActionRegistry.standard()
        registry.context.formUnion(registry.descriptor(for: "sidebar.section.rename")?.requires ?? [])
        registry.bind("sidebar.section.rename", invoke: { _ in })
        let targets = PaletteSourcesBridge.targetSource(services)
        let controller = PaletteController(registry: registry, sources: PaletteSources(targets: targets), frecencyPersistence: nil)
        registry.argumentCollector = { [weak controller] id, invocation in
            guard let controller, let descriptor = registry.descriptor(for: id) else { return }
            let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: targets)
            controller.model.reset(to: flow.effect(collected: invocation), fallback: controller.commandsPage())
        }
        let section = ActionTargetRef(kind: .sidebarSection, id: SidebarLayoutDocument.workspacesSectionID.rawValue)
        #expect(services.sidebarLayout.document.section(SidebarLayoutDocument.workspacesSectionID)?.title == nil)
        registry.perform("sidebar.section.rename", invocation: ActionInvocation(target: section))
        #expect(controller.model.isTextInput)
        #expect(controller.model.query == "")
    }
}
