public import CmuxNextActions
public import CmuxNextSidebar
import Foundation

/// The auto-archive actions (plans/cmux-next/auto-archive-DESIGN.md): Archive Idle Workspaces (the
/// sweep), Restore Archived Workspace… (the Archived list, a searchable Cmd-Shift-P step), and a
/// group's Auto-Archive rule. Every surface (the sidebar background menu, the group menu, the palette,
/// the CLI, MCP) runs these.
@MainActor
public final class AutoArchiveActions {
    /// Held for the registry's life: the bound actions are its only owner.
    private let coordinator: AutoArchiveCoordinator
    private let host: any SidebarArchiveHost
    private let store: () -> SidebarDocStore?

    /// - Parameter host: the archive actions' host (its group lookup names the invocation's group).
    public init(coordinator: AutoArchiveCoordinator, host: any SidebarArchiveHost,
                store: @escaping () -> SidebarDocStore? = { SidebarDocStore.current }) {
        self.coordinator = coordinator
        self.host = host
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
        registry.bindEffect("workspace.restoreArchived", unavailable: unavailable, effect: { [self, weak registry] invocation in
            guard let item = invocation["item"]?.stringValue, !item.isEmpty else {
                // The archived workspaces as a Cmd-Shift-P step; Return runs this again with the pick.
                guard let registry, !registry.refusalHasCaller, registry.ask("workspace.restoreArchived", invocation, ActionArgumentAsk(argument: "item"))
                else { return .refused(ArchiveStrings.autoArchiveNeedsItem) }
                return .done
            }
            let archived = self.coordinator.archivedWorkspaces().map(\.item)
            let items = item == "all" ? archived : archived.filter { $0 == item }
            guard !items.isEmpty else { return .refused(ArchiveStrings.noSuchItem) }
            self.coordinator.restore(items)
            return .done
        })
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak self] source in
            guard source == ActionSuggestions.archivedWorkspaces, let self else { return otherSuggestions?(source) ?? [] }
            return self.coordinator.archivedWorkspaces().map { ActionEnumCase(value: $0.item, title: $0.title.isEmpty ? $0.workspace : $0.title) }
        }
        #if DEBUG
        bindDebug(into: registry)
        #endif
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
                let group = try self.host.archiveGroupID(invocation)
                let item = store.records.groupItem(personal: group) ?? group
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

    #if DEBUG
    /// Debug > Age Workspaces for Auto-Archive: the clock moves `days` (default 10) ahead and a pass runs now.
    private func bindDebug(into registry: ActionRegistry) {
        registry.bindEffect("debug.autoArchive.age", unavailable: { nil }, effect: { [self] invocation in
            let days = invocation["days"]?.stringValue.flatMap(Double.init) ?? 10
            self.coordinator.debugClockSkew = days * 86_400
            self.coordinator.runPass()
            return .done
        })
    }
    #endif

    private func activeStore() -> SidebarDocStore? { store().flatMap { $0.isActive ? $0 : nil } }
}
