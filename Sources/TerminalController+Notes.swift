import Foundation
import Bonsplit
import os

nonisolated let terminalNoteLogger = Logger(subsystem: "com.cmuxterm.app", category: "notes")

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
