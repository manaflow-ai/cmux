import Foundation
import Bonsplit
import os

nonisolated private let terminalNoteLogger = Logger(subsystem: "com.cmuxterm.app", category: "notes")

private func noteAttachmentPayload(_ attachment: CmuxNoteAttachment) -> [String: Any] {
    [
        "kind": attachment.kind.rawValue,
        "workspace_anchor_id": attachment.workspaceAnchorId,
        "surface_anchor_id": (attachment.surfaceAnchorId as Any?) ?? NSNull(),
        "surface_kind": (attachment.surfaceKind as Any?) ?? NSNull(),
        "created_at": attachment.createdAt
    ]
}

private func noteRecordPayload(note: CmuxNoteRecord, path: String) -> [String: Any] {
    [
        "id": note.id,
        "slug": note.slug,
        "title": note.title,
        "body_path": note.bodyPath,
        "path": path,
        "created_at": note.createdAt,
        "updated_at": note.updatedAt,
        "attachments": note.attachments.map(noteAttachmentPayload)
    ]
}

private func noteFilePayload(path: String) -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey
    ])
    return [
        "exists": values?.isRegularFile == true,
        "size_bytes": Int64(values?.fileSize ?? 0),
        "mtime": (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970
    ]
}

extension TerminalController {
    // MARK: - Notes

    nonisolated func v2NoteCreate(params: [String: Any]) -> V2CallResult {
        let hasSlugParameter = params.keys.contains("slug")
        let providedSlug = NoteRPCParam.string(params, "slug")
        let slug: String?
        if hasSlugParameter {
            guard let providedSlug, !providedSlug.isEmpty else {
                return .err(code: "invalid_params", message: NoteRPCMessage.emptySlug, data: nil)
            }
            do {
                slug = try NoteSupport.validateSlug(providedSlug)
            } catch {
                return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
            }
        } else {
            slug = nil
        }
        return v2NoteOpenSplit(slug: slug, params: params, createIfMissing: true)
    }

    nonisolated func v2NoteOpen(params: [String: Any]) -> V2CallResult {
        guard params.keys.contains("slug") else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        guard let rawSlug = NoteRPCParam.string(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.emptySlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        return v2NoteOpenSplit(slug: slug, params: params, createIfMissing: false)
    }

    /// Shared implementation for `note.create` and `note.open` — splits the
    /// caller's pane (or focused pane) and opens the note as a markdown
    /// surface. When `createIfMissing` is true the file is ensured to exist;
    /// otherwise opening a missing slug returns `not_found`.
    private nonisolated func v2NoteOpenSplit(
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

    nonisolated func v2NoteList(params: [String: Any]) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.listFailed, data: nil)
        var currentDirectory: String?
        // Caller context for "which note do you mean" resolution: the note(s)
        // linked to the calling surface, then the workspace. Resolved off the
        // caller's surface_id (CMUX_SURFACE_ID) without minting anchors.
        var surfaceTarget: CmuxNoteAttachmentTarget?
        var workspaceTarget: CmuxNoteAttachmentTarget?
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
            currentDirectory = ws.currentDirectory
            workspaceTarget = ws.noteAttachmentTargetForWorkspace()
            if let surfaceId = v2UUID(params, "surface_id") {
                surfaceTarget = ws.existingNoteAttachmentTargetForPanel(panelId: surfaceId)
            }
        }
        guard let currentDirectory else {
            return result
        }
        let projectRoot = NoteSupport.projectRoot(forCwd: currentDirectory)
        let notes: [CmuxNoteRecord]
        do {
            notes = try CmuxNoteStore.list(projectRoot: projectRoot)
        } catch {
            // A corrupt/unreadable index must surface as a list failure — with
            // the underlying reason — not an empty list that looks like the
            // user's notes vanished.
            return .err(
                code: "internal_error",
                message: NoteRPCMessage.listFailed,
                data: ["detail": error.localizedDescription]
            )
        }
        let resolution = CmuxNoteContextResolver.resolve(
            notes: notes,
            surfaceTarget: surfaceTarget,
            workspaceTarget: workspaceTarget
        )

        func annotatedPayload(for note: CmuxNoteRecord) -> [String: Any] {
            let path = CmuxNoteStore.noteBodyPath(for: note, projectRoot: projectRoot)
            var notePayload = noteRecordPayload(note: note, path: path)
            notePayload.merge(noteFilePayload(path: path)) { _, new in new }
            notePayload["link"] = resolution.link(for: note)?.rawValue ?? NSNull()
            return notePayload
        }

        let payload = resolution.orderedNotes.map(annotatedPayload)
        var top: [String: Any] = [
            "project_root": projectRoot,
            "notes": payload,
            "resolved_slug": NSNull(),
            "resolved": NSNull()
        ]
        if let resolvedId = resolution.resolvedNoteId,
           let resolvedNote = notes.first(where: { $0.id == resolvedId }) {
            top["resolved_slug"] = resolvedNote.slug
            top["resolved"] = annotatedPayload(for: resolvedNote)
        }
        result = .ok(top)
        return result
    }

    nonisolated func v2NotePath(params: [String: Any]) -> V2CallResult {
        guard params.keys.contains("slug") else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        guard let rawSlug = NoteRPCParam.string(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.emptySlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.pathFailed, data: nil)
        var currentDirectory: String?
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
            currentDirectory = ws.currentDirectory
        }
        guard let currentDirectory else {
            return result
        }
        let projectRoot = NoteSupport.projectRoot(forCwd: currentDirectory)
        do {
            let resolved = try CmuxNoteStore.path(slug: slug, projectRoot: projectRoot)
            var payload = noteRecordPayload(note: resolved.note, path: resolved.path)
            payload.merge(noteFilePayload(path: resolved.path)) { _, new in new }
            payload["exists"] = resolved.exists
            payload["project_root"] = projectRoot
            result = .ok(payload)
        } catch {
            terminalNoteLogger.error(
                "Failed to resolve note path slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            if let storeError = error as? CmuxNoteStoreError,
               case .noteNotFound = storeError {
                return .err(
                    code: "not_found",
                    message: NoteRPCMessage.noteNotFound,
                    data: ["slug": slug, "project_root": projectRoot]
                )
            }
            return .err(
                code: "io_error",
                message: NoteRPCMessage.accessFailed,
                data: [
                    "slug": slug,
                    "project_root": projectRoot
                ]
            )
        }
        return result
    }

    nonisolated func v2NoteRead(params: [String: Any]) -> V2CallResult {
        guard params.keys.contains("slug") else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        guard let rawSlug = NoteRPCParam.string(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.emptySlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.readFailed, data: nil)
        var currentDirectory: String?
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
            currentDirectory = ws.currentDirectory
        }
        guard let currentDirectory else {
            return result
        }
        let projectRoot = NoteSupport.projectRoot(forCwd: currentDirectory)
        do {
            let read = try CmuxNoteStore.read(slug: slug, projectRoot: projectRoot)
            var payload = noteRecordPayload(note: read.note, path: read.path)
            payload.merge(noteFilePayload(path: read.path)) { _, new in new }
            payload["content"] = read.content
            payload["project_root"] = projectRoot
            result = .ok(payload)
        } catch {
            terminalNoteLogger.error(
                "Failed to read note slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            if let storeError = error as? CmuxNoteStoreError,
               case .noteNotFound = storeError {
                return .err(
                    code: "not_found",
                    message: NoteRPCMessage.noteNotFound,
                    data: ["slug": slug, "project_root": projectRoot]
                )
            }
            return .err(
                code: "io_error",
                message: NoteRPCMessage.readFailed,
                data: [
                    "slug": slug,
                    "project_root": projectRoot
                ]
            )
        }
        return result
    }

    nonisolated func v2NoteWrite(params: [String: Any]) -> V2CallResult {
        return v2NoteWriteContent(params: params, append: false)
    }

    nonisolated func v2NoteAppend(params: [String: Any]) -> V2CallResult {
        return v2NoteWriteContent(params: params, append: true)
    }

    private nonisolated func v2NoteWriteContent(params: [String: Any], append: Bool) -> V2CallResult {
        guard params.keys.contains("slug") else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        guard let rawSlug = NoteRPCParam.string(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.emptySlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        let hasContent = params.keys.contains("content")
        let hasText = params.keys.contains("text")
        guard hasContent || hasText,
              let content = NoteRPCParam.rawString(params, hasContent ? "content" : "text") else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingContent, data: nil)
        }
        let createIfMissing: Bool
        if params.keys.contains("create") {
            guard let parsed = NoteRPCParam.bool(params, "create") else {
                return .err(code: "invalid_params", message: NoteRPCMessage.invalidBoolean("create"), data: nil)
            }
            createIfMissing = parsed
        } else {
            createIfMissing = true
        }

        let failureMessage = append ? NoteRPCMessage.appendFailed : NoteRPCMessage.writeFailed
        var result: V2CallResult = .err(code: "internal_error", message: failureMessage, data: nil)
        var currentDirectory: String?
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
            currentDirectory = ws.currentDirectory
        }
        guard let currentDirectory else {
            return result
        }
        let projectRoot = NoteSupport.projectRoot(forCwd: currentDirectory)
        do {
            let written: CmuxNoteWriteResult
            if append {
                written = try CmuxNoteStore.append(
                    slug: slug,
                    title: NoteRPCParam.string(params, "title"),
                    content: content,
                    projectRoot: projectRoot,
                    createIfMissing: createIfMissing
                )
            } else {
                written = try CmuxNoteStore.write(
                    slug: slug,
                    title: NoteRPCParam.string(params, "title"),
                    content: content,
                    projectRoot: projectRoot,
                    createIfMissing: createIfMissing
                )
            }
            var payload = noteRecordPayload(note: written.note, path: written.path)
            payload.merge(noteFilePayload(path: written.path)) { _, new in new }
            payload["bytes"] = Int64(Data(content.utf8).count)
            payload["size_bytes"] = written.sizeBytes
            payload["operation"] = append ? "append" : "write"
            payload["project_root"] = projectRoot
            result = .ok(payload)
        } catch {
            terminalNoteLogger.error(
                "Failed to \(append ? "append" : "write") note slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            if let storeError = error as? CmuxNoteStoreError,
               case .noteNotFound = storeError {
                return .err(
                    code: "not_found",
                    message: NoteRPCMessage.noteNotFound,
                    data: ["slug": slug, "project_root": projectRoot]
                )
            }
            return .err(
                code: "io_error",
                message: failureMessage,
                data: [
                    "slug": slug,
                    "project_root": projectRoot
                ]
            )
        }
        return result
    }

    nonisolated func v2NoteDelete(params: [String: Any]) -> V2CallResult {
        guard params.keys.contains("slug") else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        guard let rawSlug = NoteRPCParam.string(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.emptySlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.deleteFailed, data: nil)
        var currentDirectory: String?
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
            currentDirectory = ws.currentDirectory
        }
        guard let currentDirectory else {
            return result
        }
        let projectRoot = NoteSupport.projectRoot(forCwd: currentDirectory)
        do {
            let deleted = try CmuxNoteStore.delete(slug: slug, projectRoot: projectRoot)
            result = .ok([
                "slug": slug,
                "deleted": deleted,
                "project_root": projectRoot
            ])
        } catch {
            terminalNoteLogger.error(
                "Failed to delete note slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            result = .err(
                code: "io_error",
                message: NoteRPCMessage.deleteFailed,
                data: [
                    "slug": slug,
                    "project_root": projectRoot
                ]
            )
        }
        return result
    }
}
