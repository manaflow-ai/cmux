import AppKit
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// A person's close of several selected sidebar rows as one batch (`WorkspaceSelectionCloseFlow`,
/// Leo 2026-10-21: "it's really slow and it's missing a LOT... and it's also 2 lines tall"): the
/// App's wiring of its sidebar pass, question, toast and window.
@MainActor
enum WorkspaceSelectionClose {
    /// Closes the workspaces `ids` that window `state` lists.
    static func close(_ ids: [String], in state: WindowState, _ services: AppServices) {
        let windows = services.windows, controller = windows.controller(for: state.id), shownAtPress = controller?.state.workspaceID
        let members = ids.compactMap { services.machines.workspace(id: $0) }.filter { workspace, _ in
            workspace.key != nil && !HomeRules.isHome(workspace) && WorkspaceSelectionCloseFlow.canStart(workspace.id)
        }
        let closing = members.map(\.0.id), undoWindow = WorkspaceBulkClose.survivor(closing: closing, AppActionContext(services: services))
        let incognito = members.contains { windows.isIncognito(workspace: $0.0.id) }, selected = WorkspaceCloseSelection()
        // The unpinned groups this close empties: once their rows closed, each goes as a group that lost its last live member does
        // (`PersonalGroupLife.deleteIfEmpty`, cx-rcby) instead of staying behind empty. Undo forms it again first, so its workspaces rejoin it.
        let emptied = controller?.sidebar.model.groupsEmptied(byClosing: closing.map(CmuxNextSidebar.WorkspaceID.init)) ?? []
        var undoGroups: [String] = []
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id)), warn = services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        let flow = WorkspaceSelectionCloseFlow(
            hide: { ids in
                defer { selected.afterPress = controller?.state.workspaceID }
                return InstantClose.begin(ids, in: state.id, windows: windows)
            },
            question: {
                guard var prompt = await WorkspaceBulkClose.prompt(members, warn: warn, askWithoutUndo: undoWindow == nil, incognito: incognito) else { return nil }
                prompt.returnConfirms = false
                return { await withCheckedContinuation { answer in
                    DestructiveConfirmation.present(prompt, in: controller?.window ?? windows.active?.window, settings: services.settings) { answer.resume(returning: $0) }
                } }
            },
            restore: {
                guard let shownAtPress, closing.contains(shownAtPress), services.workspace(id: shownAtPress) != nil, let controller,
                      controller.state.workspaceID == selected.afterPress else { return }
                windows.show(workspaceID: shownAtPress, in: controller.state)
            },
            listed: { services.workspace(id: $0) != nil },
            liveClosed: { _ in
                // Read from the personal rows, not the sidebar the rows (and the group) left at the press: a member another window,
                // machine or client still holds keeps the group, and the delete checks again once it is sent.
                guard let bridge = controller?.sidebar else { return }
                for id in emptied.filter({ !$0.isPinned }).map({ WorkspaceGroupID(rawValue: SidebarDocStore.personalGroupID(item: $0.id.rawValue)) }) where bridge.life.isEmptyUnpinned(id) {
                    bridge.life.deleteIfEmpty(id, failed: { bridge.resync() })
                    undoGroups.append(id.rawValue)
                }
            }, machines: { services.machines.daemons },
            offerUndo: { names, undone in
                guard names.count > 1, let undoWindow else { return }
                WorkspaceGroupClose.offerUndo("workspaces-closed", WorkspaceBulkClose.closedToast(names.count), groups: undoGroups.map { ($0, []) } + [(nil, names)], after: seen, in: undoWindow, services, undone: undone)
            },
            window: state.id, toastWindow: controller?.window)
        if let work = flow.start(members) { services.registry.track(work) }
    }
}
