import AppKit
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings

/// A person's close of several selected sidebar rows as one batch (`WorkspaceSelectionCloseFlow`,
/// Leo 2026-10-21: "it's really slow and it's missing a LOT... and it's also 2 lines tall"): the
/// App's wiring of its sidebar pass, question, toast and window.
@MainActor
enum WorkspaceSelectionClose {
    /// Closes the workspaces `ids` that window `state` lists.
    static func close(_ ids: [String], in state: WindowState, _ services: AppServices) {
        let windows = services.windows, controller = windows.controller(for: state.id), shownAtPress = controller?.state.workspaceID
        let members = ids.compactMap { services.machines.workspace(id: $0) }.filter { workspace, _ in
            workspace.key != nil && !HomeRules.isHome(workspace) && services.selectionCloses.canStart(workspace.id)
        }
        let closing = members.map(\.0.id), undoWindow = WorkspaceBulkClose.survivor(closing: closing, AppActionContext(services: services))
        let incognito = members.contains { windows.isIncognito(workspace: $0.0.id) }, selected = WorkspaceCloseSelection()
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id)), warn = services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        let flow = WorkspaceSelectionCloseFlow(
            hide: { ids in
                defer { selected.afterPress = controller?.state.workspaceID }
                // Always a person's selection close: its rows animate out even when they leave after the question
                // was answered, past the press's window for motion (calm-sidebar-movement).
                controller?.sidebar.model.noteUserIntent()
                return InstantClose.begin(ids, in: state.id, windows: windows)
            },
            // A terminal that may run a program, or nothing left to undo it: the rows stay until the person answers.
            mayAsk: { WorkspaceBulkClose.mayAsk(members, warn: warn, askWithoutUndo: undoWindow == nil) },
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
            listed: { services.workspace(id: $0) != nil }, machines: { services.machines.daemons },
            offerUndo: { names, undone in
                guard names.count > 1, let undoWindow else { return }
                WorkspaceGroupClose.offerUndo("workspaces-closed", WorkspaceBulkClose.closedToast(names.count), groups: [(nil, names)], after: seen, in: undoWindow, services, undone: undone)
            },
            window: state.id, toastWindow: controller?.window, running: services.selectionCloses)
        if let work = flow.start(members) { services.registry.track(work) }
    }
}
