public import CmuxNextActions
public import CmuxNextSidebar

/// Archive Other Workspaces, Archive Other Workspaces in Group, Archive Workspaces Below and Above
/// (user, 2026-11-05: "we need archive workspaces below/above etc"). Each archives the rows its close
/// counterpart would close (``SidebarArchiveHost/archiveRows(_:closedBy:)``: the same sidebar order,
/// the same kept selection, Home never), minus pinned rows, as one sidebar-document change: one undo
/// step and a toast whose Undo brings the whole batch back (``AutoArchiveCoordinator/archive(workspaces:)``).
/// Nothing closes, so nothing asks first. With nothing to archive the row is disabled with the reason
/// and every run (palette, CLI, MCP) is refused with it.
@MainActor
public final class WorkspaceBulkArchiveActions {
    /// Each archive action, the close whose rows it archives, and what it says when there are none.
    static let actions: [(archive: ActionID, close: ActionID, none: @MainActor () -> String)] = [
        ("workspace.archiveOtherWorkspaces", "palette.closeOtherWorkspaces", { ArchiveStrings.noOtherWorkspaces }),
        ("workspace.archiveOthersInGroup", "workspace.closeOthersInGroup", { ArchiveStrings.noOtherWorkspacesInGroup }),
        ("workspace.archiveWorkspacesBelow", "palette.closeWorkspacesBelow", { ArchiveStrings.noWorkspacesBelow }),
        ("workspace.archiveWorkspacesAbove", "palette.closeWorkspacesAbove", { ArchiveStrings.noWorkspacesAbove }),
    ]

    /// Held for the registry's life: the bound actions are its only owner.
    private let coordinator: AutoArchiveCoordinator
    private let host: any SidebarArchiveHost

    /// - Parameters:
    ///   - coordinator: Archives the rows as one undo step and shows the toast.
    ///   - host: Names the rows each close would close.
    public init(coordinator: AutoArchiveCoordinator, host: any SidebarArchiveHost) {
        self.coordinator = coordinator
        self.host = host
    }

    /// Binds the four archive actions and their nothing-to-archive reasons into `registry`.
    public func bind(into registry: ActionRegistry) {
        for (id, close, none) in Self.actions {
            registry.bindEffect(id, unavailable: { nil }, effect: { [self] invocation in self.run(close, none, invocation) })
            ActionTargetReasons.set(id, in: registry) { [self, weak registry] invocation in
                registry?.withoutRefusals {
                    guard let rows = try? self.host.archiveRows(invocation, closedBy: close) else { return nil }
                    return self.coordinator.archivableItems(workspaces: rows).isEmpty ? none() : nil
                }
            }
        }
    }

    private func run(_ close: ActionID, _ none: @MainActor () -> String, _ invocation: ActionInvocation) -> ActionEffect {
        let rows: [String]
        do { rows = try host.archiveRows(invocation, closedBy: close) } catch { return .refused(host.archiveRefusal(error)) }
        do throws(AutoArchiveRefusal) {
            return try coordinator.archive(workspaces: rows) == 0 ? .refused(none()) : .done
        } catch {
            return .refused(error.message)
        }
    }
}
