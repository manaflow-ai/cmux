import CmuxNextActions
import CmuxNextDaemon

/// Saved tab groups (Chrome "save group"): session-wide daemon records
/// (architecture.md 1 and 7). Reopen restores one into the targeted or
/// focused pane; delete removes the record and leaves an open copy open.
/// The `group` argument accepts the saved id or the id of its open group.
enum SavedGroupHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("tabGroup.reopenSaved", requires: DaemonCapabilities.tabGroups, daemon: context.services.daemon, run: { invocation in
            let id = try savedGroup(invocation, context).id
            let pane = context.scope(invocation).pane?.pane.handle
            Task {
                await context.services.daemon.perform("open-saved-tab-group", patch: .custom { _ in }) { connection, transaction in
                    _ = try await connection.openSavedTabGroup(id, in: pane, transaction: transaction)
                }
            }
        })
        registry.bind("tabGroup.deleteSaved", requires: DaemonCapabilities.tabGroups, daemon: context.services.daemon, run: { invocation in
            let id = try savedGroup(invocation, context).id
            context.services.daemon.send("unsave-tab-group") { try await $0.unsaveTabGroup(id) }
        })
    }

    private static func savedGroup(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> SavedTabGroupModel {
        try context.require(DaemonCapabilities.tabGroups)
        guard let raw = (invocation["group"]?.targetValue ?? invocation.target.flatMap { $0.kind == .tabGroup ? $0 : nil })?.id else {
            throw ActionFailure.invalidTarget("group is required (a saved tab group id)")
        }
        let all = context.store.savedTabGroups
        guard let saved = all.first(where: { $0.id.rawValue == raw }) ?? all.first(where: { $0.openGroup?.rawValue == raw }) else {
            throw ActionFailure.invalidTarget("no saved tab group \(raw)")
        }
        return saved
    }
}
