import AppKit
import CmuxSettings
import CmuxWorkspaces
import Foundation
import UniformTypeIdentifiers

/// The remote workspace todo controls feature gate and the shared UI
/// entry points for mutating a workspace's todo state. Every UI surface
/// (sidebar row, context menu, command palette, keyboard shortcut) funnels
/// through ``WorkspaceTodoActions`` so gated status/add-item mutations and the
/// backend caps/anti-rot apply identically everywhere.
enum WorkspaceTodoFeature {
    /// Synchronous read of the local beta opt-in plus remote-enabled feature
    /// flag for status and add-item controls. Existing checklist items stay
    /// visible/usable when this is off; only the controls that create items or
    /// set workspace completion/status lanes are hidden.
    @MainActor
    static var isEnabled: Bool {
        isEnabled(
            defaults: .standard,
            remoteEnabled: CmuxFeatureFlags.shared.isWorkspaceTodoControlsEnabled
        )
    }

    static func isEnabled(defaults: UserDefaults, remoteEnabled: Bool) -> Bool {
        remoteEnabled || localControlsOptIn(defaults: defaults)
    }

    static func localControlsOptIn(defaults: UserDefaults) -> Bool {
        let key = BetaFeaturesCatalogSection().workspaceTodoControls
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

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
        guard WorkspaceTodoFeature.isEnabled else { return }
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

    /// Opts each workspace out of the status feature (None).
    static func hideStatus(for workspaces: [Workspace]) {
        guard WorkspaceTodoFeature.isEnabled else { return }
        guard !workspaces.isEmpty else { return }
        for workspace in workspaces {
            workspace.hideTaskStatus()
        }
        WorkspaceTodoFeature.markUsed()
    }

    /// Cycles the workspace's status one lane forward (see
    /// `Workspace.cycleTaskStatus`). Shared by the `cycleWorkspaceStatus`
    /// shortcut and the `workspace.status.cycle` socket verb / CLI.
    static func cycleStatus(for workspace: Workspace) {
        guard WorkspaceTodoFeature.isEnabled else { return }
        workspace.cycleTaskStatus()
        WorkspaceTodoFeature.markUsed()
    }

    /// Adds a user checklist item; returns whether the add succeeded.
    @discardableResult
    static func addChecklistItem(text: String, to workspace: Workspace) -> Bool {
        guard WorkspaceTodoFeature.isEnabled else { return false }
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

    /// Adds one or more user-selected image files to a checklist item.
    @discardableResult
    static func addImageAttachments(to itemId: UUID, in workspace: Workspace) -> Bool {
        let attachments = pickChecklistImageAttachments()
        guard !attachments.isEmpty,
              workspace.addChecklistAttachments(itemId: itemId, attachments: attachments) else {
            return false
        }
        WorkspaceTodoFeature.markUsed()
        return true
    }

    /// Removes one image attachment reference from a checklist item.
    static func removeImageAttachment(itemId: UUID, attachmentId: UUID, from workspace: Workspace) {
        guard workspace.removeChecklistAttachment(itemId: itemId, attachmentId: attachmentId) else { return }
        WorkspaceTodoFeature.markUsed()
    }

    /// Opens a checklist item's image attachments in native Quick Look.
    static func openImageAttachments(
        _ attachments: [WorkspaceChecklistAttachment],
        selectedAttachmentId: UUID?
    ) {
        WorkspaceChecklistAttachmentQuickLookController().present(
            attachments: attachments,
            selectedAttachmentId: selectedAttachmentId
        )
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
        guard WorkspaceTodoFeature.isEnabled else { return }
        WorkspaceTodoFeature.markUsed()
        NotificationCenter.default.post(
            name: .workspaceChecklistAddItemRequested,
            object: nil,
            userInfo: [Self.workspaceIdUserInfoKey: workspaceId]
        )
    }

    static let workspaceIdUserInfoKey = "workspaceId"
}

@MainActor
private func pickChecklistImageAttachments() -> [WorkspaceChecklistAttachment] {
    let panel = NSOpenPanel()
    panel.title = String(localized: "sidebar.checklist.attachImages", defaultValue: "Attach Images…")
    panel.prompt = String(localized: "sidebar.checklist.attachImages.confirm", defaultValue: "Attach")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.image]

    guard panel.runModal() == .OK else { return [] }
    return panel.urls.map(checklistImageAttachment(for:))
}

private func checklistImageAttachment(for url: URL) -> WorkspaceChecklistAttachment {
    let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .localizedNameKey])
    let displayName = resourceValues?.localizedName ?? FileManager.default.displayName(atPath: url.path)
    return WorkspaceChecklistAttachment(
        displayName: displayName,
        fileURL: url,
        byteCount: resourceValues?.fileSize.map(Int64.init),
        contentTypeIdentifier: resourceValues?.contentType?.identifier
    )
}

extension Notification.Name {
    /// Posted by ``WorkspaceTodoActions/requestChecklistAddField(workspaceId:)``;
    /// observed by the workspace sidebar, which arms the row's add-item
    /// field — via the anchored checklist popover in `.popover` style (even
    /// for a workspace's very first item), or by expanding the row's inline
    /// checklist in `.inline` style.
    static let workspaceChecklistAddItemRequested = Notification.Name(
        "cmux.workspaceChecklistAddItemRequested"
    )
}
