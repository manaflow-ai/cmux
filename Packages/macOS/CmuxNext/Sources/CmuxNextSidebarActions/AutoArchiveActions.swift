public import CmuxNextActions
public import CmuxNextSidebar
import Foundation

/// The auto-archive actions (plans/cmux-next/auto-archive-DESIGN.md): Archive Idle Workspaces (the
/// sweep), Show Archived Workspaces (the page the App opens), and a group's Auto-Archive rule. Every
/// surface (the sidebar background menu, the group menu, the palette, the CLI, MCP) runs these.
@MainActor
public final class AutoArchiveActions {
    /// Held for the registry's life: the bound actions are its only owner.
    private let coordinator: AutoArchiveCoordinator
    private let groupItem: @MainActor (ActionInvocation) throws -> String
    private let showArchived: @MainActor (ActionInvocation) -> Void
    private let store: () -> SidebarDocStore?

    /// - Parameters:
    ///   - groupItem: the document item of the invocation's group (throws when it targets none).
    ///   - showArchived: opens the Archived Workspaces page.
    public init(coordinator: AutoArchiveCoordinator, groupItem: @escaping @MainActor (ActionInvocation) throws -> String,
                showArchived: @escaping @MainActor (ActionInvocation) -> Void,
                store: @escaping () -> SidebarDocStore? = { SidebarDocStore.current }) {
        self.coordinator = coordinator
        self.groupItem = groupItem
        self.showArchived = showArchived
        self.store = store
    }

    public func bind(into registry: ActionRegistry) {
        let unavailable: @MainActor () -> String? = { [self] in self.activeStore() == nil ? ArchiveStrings.needsDocument : nil }
        registry.bindEffect("workspace.archiveIdle", unavailable: unavailable, effect: { [self] _ in
            do throws(AutoArchiveRefusal) {
                try self.coordinator.sweep()
                return .done
            } catch {
                return .refused(error.message)
            }
        })
        registry.bindEffect("workspace.showArchived", unavailable: unavailable, effect: { [self] invocation in
            self.showArchived(invocation)
            return .done
        })
        registry.bindEffect("workspaceGroup.setAutoArchive", unavailable: unavailable, effect: { [self] invocation in
            guard let store = self.activeStore() else { return .refused(ArchiveStrings.needsDocument) }
            let rule: Any
            switch invocation["after"]?.stringValue ?? "default" {
            case "default": rule = NSNull()
            case "never": rule = SidebarDocAutoArchiveRule.never.wire
            case let text:
                guard let hours = Int(text), let value = SidebarDocAutoArchiveRule(wire: NSNumber(value: hours)) else {
                    return .refused(ArchiveStrings.autoArchiveBadRule)
                }
                rule = value.wire
            }
            do {
                let item = try self.groupItem(invocation)
                try store.sendChecked(ops: [["op": "group.update", "id": item, "patch": ["auto_archive": rule]]],
                                      title: ArchiveStrings.autoArchiveRuleTitle)
                return .done
            } catch let refusal as SidebarDocSendRefusal {
                return .refused(refusal.message)
            } catch {
                return .refused(ArchiveStrings.noSuchItem)
            }
        })
    }

    private func activeStore() -> SidebarDocStore? { store().flatMap { $0.isActive ? $0 : nil } }
}
