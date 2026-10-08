import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// Sidebar section actions through the registry (plans/cmux-next/sidebar-sections.md 6):
/// refused until the store serves `sidebar-layout-v1`; with the DEV local
/// prototype they remove and re-add Home, add, move, restyle and remove
/// sections, and the right-click menus list them for their target.
@MainActor @Suite(.serialized) struct SidebarSectionActionTests {
    private func withPrototype(_ on: Bool, _ body: () throws -> Void) rethrows {
        let store = TunableStore.shared
        store.register(SidebarSectionTunables.all)
        store.activate(file: nil)
        store.set(SidebarSectionTunables.localPrototype.descriptor.key, on ? .bool(true) : nil)
        defer { store.set(SidebarSectionTunables.localPrototype.descriptor.key, nil) }
        try body()
    }

    private func make() -> (ActionRegistry, SidebarLayoutService) {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = ActionRegistry.standard()
        SidebarSectionHandlers.bind(into: registry, context: AppActionContext(services: services))
        return (registry, services.sidebarLayout)
    }

    @Test func editsAreRefusedWithoutTheStoreCapability() {
        withPrototype(false) {
            let (registry, layout) = make()
            #expect(!registry.canPerform("sidebar.home.remove"))
            _ = registry.perform("sidebar.home.remove")
            #expect(layout.document == .defaults)
        }
    }

    @Test func removeAndReAddHome() {
        withPrototype(true) {
            let (registry, layout) = make()
            #expect(!registry.canPerform("sidebar.home.add"))
            #expect(registry.perform("sidebar.home.remove"))
            #expect(layout.document.firstItem(with: .app("cmux/home")) == nil)
            #expect(!registry.canPerform("sidebar.home.remove"))
            #expect(registry.perform("sidebar.home.add"))
            #expect(layout.document.firstTopItem(room: nil)?.ref == .app("cmux/home"))
        }
    }

    @Test func rightClickRemoveTargetsTheItem() {
        withPrototype(true) {
            let (registry, layout) = make()
            let target = ActionTargetRef(kind: .sidebarItem, id: "itm_account")
            #expect(registry.perform("sidebar.item.remove", invocation: ActionInvocation(target: target)))
            #expect(layout.document.item(LayoutItemID("itm_account")) == nil)
            // A built-in name also names the item (`cmux sidebar item remove home`).
            #expect(registry.perform("sidebar.item.remove", invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: "home"))))
            #expect(layout.document.firstItem(with: .app("cmux/home")) == nil)
        }
    }

    @Test func addMoveRestyleAndRemoveASection() throws {
        try withPrototype(true) {
            let (registry, layout) = make()
            #expect(registry.perform("sidebar.section.add", invocation: ActionInvocation(arguments: ["title": .string("Tools"), "region": .string("bottom")])))
            let added = try #require(layout.document.sections.first { $0.title == "Tools" })
            #expect(added.region == .bottom)
            let target = ActionInvocation(target: ActionTargetRef(kind: .sidebarSection, id: added.id.rawValue))
            #expect(registry.perform("sidebar.section.moveToTop", invocation: target))
            #expect(layout.document.section(added.id)?.region == .top)
            #expect(registry.perform("sidebar.section.useBuiltInLook", invocation: target))
            #expect(layout.document.section(added.id)?.look == .builtIn)
            #expect(registry.perform("sidebar.item.add", invocation: ActionInvocation(arguments: ["item": .string("history"), "section": .string("Tools")])))
            #expect(layout.document.section(added.id)?.items.map(\.ref) == [.builtIn(.history)])
            #expect(registry.perform("sidebar.section.remove", invocation: target.confirmed()))
            #expect(layout.document.section(added.id) == nil)
            #expect(registry.perform("sidebar.layout.reset", invocation: ActionInvocation().confirmed()))
            #expect(layout.document.sections == SidebarLayoutDocument.defaults.sections)
        }
    }

    @Test func removeFromSidebarTakesEveryCopyRemoveFromSectionOne() {
        withPrototype(true) {
            let (registry, layout) = make()
            #expect(registry.perform("sidebar.item.add", invocation: ActionInvocation(arguments: ["item": .string("home"), "section": .string("sec_bottom")])))
            #expect(layout.document.sections.flatMap(\.items).filter { $0.ref == .app("cmux/home") }.count == 2)
            #expect(registry.perform("sidebar.item.remove", invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: "itm_home"))))
            #expect(layout.document.sections.flatMap(\.items).filter { $0.ref == .app("cmux/home") }.count == 1)
            #expect(registry.perform("sidebar.item.removeEverywhere", invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: "home"))))
            #expect(layout.document.firstItem(with: .app("cmux/home")) == nil)
            #expect(layout.document.firstTopItem(room: nil)?.ref == .app("cmux/app-store"))
        }
    }

    @Test func theWorkspacesSectionCannotBeRemoved() {
        withPrototype(true) {
            let (registry, layout) = make()
            let target = ActionTargetRef(kind: .sidebarSection, id: SidebarLayoutDocument.workspacesSectionID.rawValue)
            _ = registry.perform("sidebar.section.remove", invocation: ActionInvocation(target: target).confirmed())
            #expect(layout.document.section(SidebarLayoutDocument.workspacesSectionID) != nil)
        }
    }

    @Test func menusListTheActionsForTheirTarget() {
        let menus = ContextMenuCatalog.shared
        func ids(_ context: ActionMenuContext) -> [ActionID] { menus.referencedIDs(menus.entries(for: context)) }
        #expect(ids(.sidebarSection).contains("sidebar.section.rename") && ids(.sidebarSection).contains("sidebar.section.remove"))
        #expect(ids(.sidebarItem).contains("sidebar.item.remove") && ids(.sidebarItem).contains("sidebar.item.removeEverywhere"))
        #expect(ids(.sidebarItem).contains("sidebar.item.hideApp") && ids(.sidebarSection).contains("sidebar.item.hideApp"))
        #expect(ids(.sidebarBackground).contains("sidebar.home.add"))
    }
}
