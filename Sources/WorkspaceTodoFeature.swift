import CmuxSettings
import CmuxWorkspaces
import Foundation

/// The `sidebar.beta.workspaceTodos.enabled` feature gate and the shared UI
/// entry points for mutating a workspace's todo state. Every UI surface
/// (sidebar row, context menu, command palette, keyboard shortcut) funnels
/// through ``WorkspaceTodoActions`` so the progressive-disclosure auto-enable
/// and the backend caps/anti-rot apply identically everywhere; the socket
/// handler in `TerminalController+ControlWorkspaceTodoContext.swift` calls
/// ``WorkspaceTodoFeature/markUsed()`` on its own successful mutations.
enum WorkspaceTodoFeature {
    /// Synchronous read of the feature flag for on-demand paths. Reads only
    /// the beta catalog section, not the whole `SettingCatalog`, so a
    /// body-path access stays cheap (see issue #5970); reactive row reads go
    /// through `SidebarTabItemSettingsSnapshot`.
    /// The workspace-todos feature is always on (accessed via the row context
    /// menu and status glyph); the Settings feature-flag toggle was removed.
    static var isEnabled: Bool { true }

    /// The checklist presentation style (popover or inline), user-selectable.
    static var checklistStyle: WorkspaceTodoChecklistStyle {
        let key = BetaFeaturesCatalogSection().workspaceTodosChecklistStyle
        return WorkspaceTodoChecklistStyle.decodeFromUserDefaults(
            UserDefaults.standard.object(forKey: key.userDefaultsKey)
        ) ?? key.defaultValue
    }

    /// No-op now that the feature is always on (kept so existing call sites
    /// stay unchanged).
    @MainActor
    static func markUsed() {}
}

/// Shared todo mutations used by the context menu, command palette, and the
/// `markWorkspaceDone` keyboard shortcut. All calls delegate to the
/// `Workspace+Todos` entry points (the same path the socket and CLI use) and
/// mark the feature used on success.
@MainActor
enum WorkspaceTodoActions {
    /// Applies a manual status override (`nil` returns the status to
    /// automatic) to every target workspace.
    static func applyStatusOverride(_ status: WorkspaceTaskStatus?, to workspaces: [Workspace]) {
        guard !workspaces.isEmpty else { return }
        for workspace in workspaces {
            if let status {
                workspace.setTaskStatusOverride(status)
            } else {
                workspace.clearTaskStatusOverride()
            }
        }
        WorkspaceTodoFeature.markUsed()
    }

    /// Opts each workspace out of the status feature (None): hide the glyph.
    static func hideStatus(for workspaces: [Workspace]) {
        guard !workspaces.isEmpty else { return }
        for workspace in workspaces {
            workspace.hideTaskStatus()
        }
        WorkspaceTodoFeature.markUsed()
    }

    /// The glyph's option-click one-step toggle: pin `.done` unless the
    /// workspace already reads done, in which case return it to automatic.
    static func toggleDone(for workspace: Workspace) {
        if workspace.effectiveTaskStatus == .done {
            applyStatusOverride(nil, to: [workspace])
        } else {
            applyStatusOverride(.done, to: [workspace])
        }
    }

    /// Cycles the workspace's status one lane forward (see
    /// `Workspace.cycleTaskStatus`). Shared by the `cycleWorkspaceStatus`
    /// shortcut and the `workspace.status.cycle` socket verb / CLI.
    static func cycleStatus(for workspace: Workspace) {
        workspace.cycleTaskStatus()
        WorkspaceTodoFeature.markUsed()
    }

    /// Adds a user checklist item; returns whether the add succeeded.
    @discardableResult
    static func addChecklistItem(text: String, to workspace: Workspace) -> Bool {
        switch workspace.addChecklistItem(text: text, state: .pending, origin: .user) {
        case .success:
            WorkspaceTodoFeature.markUsed()
            return true
        case .failure:
            return false
        }
    }

    /// Sets one checklist item's state.
    static func setChecklistItemState(
        id: UUID,
        state: WorkspaceChecklistItem.State,
        in workspace: Workspace
    ) {
        guard workspace.setChecklistItemState(id: id, state: state) else { return }
        WorkspaceTodoFeature.markUsed()
    }

    /// Removes one checklist item.
    /// Rewrites one checklist item's text (empty text is a no-op).
    static func editChecklistItem(id: UUID, text: String, in workspace: Workspace) {
        guard workspace.setChecklistItemText(id: id, text: text) else { return }
        WorkspaceTodoFeature.markUsed()
    }

    static func removeChecklistItem(id: UUID, from workspace: Workspace) {
        guard workspace.removeChecklistItem(id: id) else { return }
        WorkspaceTodoFeature.markUsed()
    }

    /// Moves one checklist item toward a new 0-based position (staying within
    /// its completion partition). Shared by the todo pane's drag reorder, the
    /// `workspace.todo.move` socket verb, and `cmux todo move`.
    static func moveChecklistItem(id: UUID, toIndex: Int, in workspace: Workspace) {
        guard workspace.moveChecklistItem(id: id, toIndex: toIndex) else { return }
        WorkspaceTodoFeature.markUsed()
    }

    /// Opens (or focuses) the workspace's todo pane in the workspace's
    /// focused pane. One shared path for the checklist popover footer, the
    /// command palette, `cmux todo open`, and the `workspace.todo.open`
    /// socket verb. Also enables the feature (opening the pane is using it).
    @discardableResult
    static func openTodoPane(for workspace: Workspace, focus: Bool = true) -> WorkspaceTodoPanel? {
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            return nil
        }
        guard let panel = workspace.openOrFocusWorkspaceTodoSurface(inPane: paneId, focus: focus) else {
            return nil
        }
        WorkspaceTodoFeature.markUsed()
        return panel
    }

    /// Asks the sidebar to expand a workspace row's checklist and focus its
    /// add-item field (used by the context menu and the command palette,
    /// which have no direct handle on the row's transient UI state). Also
    /// enables the feature so the checklist UI is actually visible.
    static func requestChecklistAddField(workspaceId: UUID) {
        WorkspaceTodoFeature.markUsed()
        NotificationCenter.default.post(
            name: .workspaceChecklistAddItemRequested,
            object: nil,
            userInfo: [Self.workspaceIdUserInfoKey: workspaceId]
        )
    }

    static let workspaceIdUserInfoKey = "workspaceId"
}

extension Notification.Name {
    /// Posted by ``WorkspaceTodoActions/requestChecklistAddField(workspaceId:)``;
    /// observed by the workspace sidebar, which expands the row's checklist
    /// and arms its add-item field.
    static let workspaceChecklistAddItemRequested = Notification.Name(
        "cmux.workspaceChecklistAddItemRequested"
    )
}
