import Bonsplit
import Foundation
import os

extension TerminalController {
    nonisolated func v2NoteOpenSplit(
        slug: String?,
        params: [String: Any],
        createIfMissing: Bool
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.openFailed, data: nil)
        var resolvedWorkspaceId: UUID?
        var resolvedCurrentDirectory: String?
        var resolvedSourceSurfaceId: UUID?
        var resolvedOrientation: SplitOrientation?
        var resolvedInsertFirst = false
        var resolvedFocusAllowed = false
        var resolvedAttachment: CmuxNoteAttachmentTarget?
        v2MainSync {
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: NoteRPCMessage.tabManagerUnavailable, data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: NoteRPCMessage.workspaceNotFound, data: nil)
                return
            }
            guard !ws.isRemoteWorkspace else {
                result = .err(code: "unavailable", message: NoteRPCMessage.remoteUnavailable, data: nil)
                return
            }

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: NoteRPCMessage.focusSurfaceMissing, data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(
                    code: "not_found",
                    message: NoteRPCMessage.sourceSurfaceNotFound,
                    data: ["surface_id": sourceSurfaceId.uuidString]
                )
                return
            }

            let directionStr = NoteRPCParam.string(params, "direction") ?? "right"
            guard let direction = parseSplitDirection(directionStr) else {
                result = .err(
                    code: "invalid_params",
                    message: NoteRPCMessage.invalidDirection(directionStr),
                    data: nil
                )
                return
            }
            let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
            let insertFirst = (direction == .left || direction == .up)
            let focusAllowed = v2FocusAllowed(requested: NoteRPCParam.bool(params, "focus") ?? false)
            let attachModeRaw = (NoteRPCParam.string(params, "attach") ?? (createIfMissing ? "surface" : "none")).lowercased()
            guard let attachMode = NoteRPCAttachMode(rawValue: attachModeRaw) else {
                result = .err(
                    code: "invalid_params",
                    message: NoteRPCMessage.invalidAttachMode(attachModeRaw),
                    data: nil
                )
                return
            }
            let attachment: CmuxNoteAttachmentTarget?
            switch attachMode {
            case .none:
                attachment = nil
            case .workspace:
                attachment = ws.noteAttachmentTargetForWorkspace()
            case .surface:
                attachment = ws.noteAttachmentTargetForPanel(panelId: sourceSurfaceId)
            case .terminal:
                guard let target = ws.noteAttachmentTargetForPanel(
                    panelId: sourceSurfaceId,
                    requireTerminal: true
                ) else {
                    result = .err(
                        code: "invalid_params",
                        message: NoteRPCMessage.terminalAttachRequiresTerminal,
                        data: ["surface_id": sourceSurfaceId.uuidString]
                    )
                    return
                }
                attachment = target
            }

            resolvedWorkspaceId = ws.id
            resolvedCurrentDirectory = ws.currentDirectory
            resolvedSourceSurfaceId = sourceSurfaceId
            resolvedOrientation = orientation
            resolvedInsertFirst = insertFirst
            resolvedFocusAllowed = focusAllowed
            resolvedAttachment = attachment
        }

        guard let workspaceId = resolvedWorkspaceId,
              let currentDirectory = resolvedCurrentDirectory,
              let sourceSurfaceId = resolvedSourceSurfaceId,
              let orientation = resolvedOrientation else {
            return result
        }
        let projectRoot = NoteSupport.projectRoot(forCwd: currentDirectory)
        let noteResult: CmuxNoteStoreResult
        do {
            noteResult = try CmuxNoteStore.createOrOpen(
                slug: slug,
                title: NoteRPCParam.string(params, "title"),
                projectRoot: projectRoot,
                createIfMissing: createIfMissing,
                attachment: resolvedAttachment,
                // `note new` always creates a fresh note (matching the GUI New
                // Note button and the issue-4331 spec) rather than reopening the
                // surface's existing note — notes are unlimited per surface. To
                // get back to "the note for this surface", callers use
                // `note here`/`note list`, which resolve the most-recent linked
                // note. `note open <slug>` still targets a specific note.
                preferAttachedExisting: false
            )
        } catch {
            terminalNoteLogger.error(
                "Failed to open note slug=\(slug ?? "nil", privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            if let storeError = error as? CmuxNoteStoreError,
               case .noteNotFound(let missingSlug) = storeError {
                return .err(
                    code: "not_found",
                    message: NoteRPCMessage.noteNotFound,
                    data: ["slug": missingSlug, "project_root": projectRoot]
                )
            }
            return .err(
                code: "io_error",
                message: createIfMissing ? NoteRPCMessage.createFailed : NoteRPCMessage.accessFailed,
                data: [
                    "slug": slug ?? "",
                    "path": slug.map { NoteSupport.notePath(forSlug: $0, projectRoot: projectRoot) } ?? "",
                    "project_root": projectRoot
                ]
            )
        }
        // Project notes are writing surfaces first. Keep them in edit mode by
        // default; preview remains one click away in the panel toolbar.
        let openInTextMode = true
        let notePath = noteResult.path
        let standardizedNotePath = (notePath as NSString).standardizingPath
        let note = noteResult.note
        let hasRequestedAttachment = resolvedAttachment.map { target in
            note.attachments.contains(where: { $0.matches(target) })
        } ?? false
        let reuseCandidates = v2MainSync { () -> [NoteReuseCandidate] in
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let ws = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return []
            }
            return ws.panels.compactMap { panelId, panel in
                guard let md = panel as? MarkdownPanel else { return nil }
                return NoteReuseCandidate(
                    panelId: panelId,
                    filePath: md.filePath,
                    noteID: md.noteID,
                    noteBodyPath: md.noteBodyPath
                )
            }
        }
        var resolvedNotePath: String?
        let reusablePanelId = reuseCandidates.first { candidate in
            if (candidate.filePath as NSString).standardizingPath == standardizedNotePath {
                return true
            }
            guard candidate.noteID == note.id || candidate.noteBodyPath == note.bodyPath else {
                return false
            }
            if resolvedNotePath == nil {
                resolvedNotePath = (notePath as NSString).resolvingSymlinksInPath
            }
            return (candidate.filePath as NSString).resolvingSymlinksInPath == resolvedNotePath
        }?.panelId

        v2MainSync {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let ws = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: NoteRPCMessage.workspaceNotFound, data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(
                    code: "not_found",
                    message: NoteRPCMessage.sourceSurfaceNotFound,
                    data: ["surface_id": sourceSurfaceId.uuidString]
                )
                return
            }
            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            // Reuse an existing markdown panel that already shows this note,
            // so repeated `cmux note open <slug>` focuses rather than spawns
            // duplicates. Mirrors openOrFocusMarkdownSurface semantics.
            if let existingId = reusablePanelId,
               let md = ws.panels[existingId] as? MarkdownPanel {
                md.markAsProjectNote(
                    slug: note.slug,
                    id: note.id,
                    bodyPath: note.bodyPath,
                    title: note.title
                )
                if openInTextMode {
                    md.setDisplayMode(.text, focusTextEditor: resolvedFocusAllowed)
                }
                if resolvedFocusAllowed {
                    ws.focusPanel(existingId)
                }
                let targetPaneUUID = ws.paneId(forPanelId: existingId)?.id
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                var payload = noteRecordPayload(note: note, path: notePath)
                payload.merge([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                    "surface_id": existingId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: existingId),
                    "source_surface_id": sourceSurfaceId.uuidString,
                    "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                    "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                    "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                    "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                    "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                    "project_root": projectRoot,
                    "created": noteResult.created,
                    "attached": hasRequestedAttachment,
                    "attachment_created": noteResult.attached,
                    "reused": true
                ]) { _, new in new }
                result = .ok(payload)
                return
            }

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: resolvedInsertFirst,
                filePath: notePath,
                focus: resolvedFocusAllowed
            )

            guard let panel = createdPanel else {
                result = .err(code: "internal_error", message: NoteRPCMessage.surfaceCreateFailed, data: nil)
                return
            }
            panel.markAsProjectNote(
                slug: note.slug,
                id: note.id,
                bodyPath: note.bodyPath,
                title: note.title
            )
            if openInTextMode {
                panel.setDisplayMode(.text, focusTextEditor: resolvedFocusAllowed)
            }

            let targetPaneUUID = ws.paneId(forPanelId: panel.id)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            var payload = noteRecordPayload(note: note, path: notePath)
            payload.merge([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "project_root": projectRoot,
                "created": noteResult.created,
                "attached": hasRequestedAttachment,
                "attachment_created": noteResult.attached,
                "reused": false
            ]) { _, new in new }
            result = .ok(payload)
        }
        return result
    }
}
