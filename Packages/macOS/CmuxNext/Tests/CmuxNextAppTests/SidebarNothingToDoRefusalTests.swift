import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Sidebar actions that cannot act say why, or are not offered (unimpl-audit-actions.md rows 19,
/// 30, 41): Move Workspace Group Up/Down/to Top/to Bottom at the edge, Next/Previous Workspace
/// Group with no group to go to, and Move Section to Bottom (the sidebar has no bottom area).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)))
struct SidebarNothingToDoRefusalTests {
    private static func allItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
        items.flatMap { [$0] + ($0.submenu.map { allItems($0.items) } ?? []) }
    }

    /// The sidebar has no bottom area, so no menu or palette offers a move there.
    @Test func noSurfaceOffersMoveSectionToBottom() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let menu = services.registry.makeContextMenu(for: .sidebarSection, target: ActionTargetRef(kind: .sidebarSection, id: "sec_test"))
        let runs = Self.allItems(menu.items).compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue }
        #expect(runs.contains("sidebar.section.moveToTop"), "the section menu lost its moves: \(runs)")
        #expect(!runs.contains("sidebar.section.moveToBottom"), "the section menu offers Move Section to Bottom, which never runs")
        let offered = services.registry.descriptor(for: "sidebar.section.moveToBottom")?.surfacePlan.palette.isOffered ?? false
        #expect(!offered, "the palette offers Move Section to Bottom, which never runs")
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func groupMovesAtTheEdgeSayWhy() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let workspace = try #require(services.windows.registry.members(of: window.state.id).compactMap(services.workspace(id:))
                .first { !HomeRules.isHome($0) })
            let context = AppActionContext(services: services)
            try await PinnedPageTests.until({ services.machines.local.store.personal.isLoaded }, report: { "personal state never loaded" })
            // A person's Group Workspace (a group made by `.cli` is not drawn in the sidebar yet: a separate gap).
            _ = services.registry.perform("newWorkspaceGroup", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .workspace, id: workspace.id), arguments: ["name": .string("Only")]))
            try await PinnedPageTests.until({ (try? WorkspaceVerbHandlers.group(of: workspace, context)) != nil }, report: { "the sidebar shows no group" })
            let group = try #require(context.personalGroupID(of: workspace))
            // The window's only row: it is at the top and at the bottom.
            let target = ActionTargetRef(kind: .workspaceGroup, id: group.rawValue)
            for id: ActionID in ["workspaceGroup.moveUp", "workspaceGroup.moveDown", "workspaceGroup.moveToTop", "workspaceGroup.moveToBottom"] {
                let menu = ActionTargetReasons.reason(for: id, invocation: ActionInvocation(target: target), in: services.registry)
                let cli = services.registry.capturingRefusal { _ = services.registry.perform(id, invocation: ActionInvocation(target: target, origin: .cli)) }
                #expect(menu != nil, "\(id) on the only row is enabled and does nothing")
                #expect(cli != nil && cli == menu, "\(id): a CLI run reports \(cli ?? "success") instead of the row's reason")
            }
        }
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func nextWorkspaceGroupWithNoGroupSaysWhy() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try #require(AppActionContext(services: services).roomGroups.isEmpty, "the room starts with groups")
            for id: ActionID in ["nextWorkspaceGroup", "prevWorkspaceGroup"] {
                let cli = services.registry.capturingRefusal { _ = services.registry.perform(id, invocation: ActionInvocation(origin: .cli)) }
                #expect(cli != nil, "\(id) with no group reports success and goes nowhere")
            }
        }
    }
}
