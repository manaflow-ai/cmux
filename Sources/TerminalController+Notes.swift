import Foundation
import Bonsplit
import os

nonisolated private let terminalNoteLogger = Logger(subsystem: "com.cmuxterm.app", category: "notes")

private enum NoteRPCMessage {
    static let missingSlug = String(localized: "rpc.note.error.missingSlug", defaultValue: "Missing 'slug' parameter")
    static let emptySlug = String(localized: "rpc.note.error.emptySlug", defaultValue: "slug must not be empty")
    static let tabManagerUnavailable = String(localized: "rpc.note.error.tabManagerUnavailable", defaultValue: "TabManager not available")
    static let openFailed = String(localized: "rpc.note.error.openFailed", defaultValue: "Failed to open note")
    static let workspaceNotFound = String(localized: "rpc.note.error.workspaceNotFound", defaultValue: "Workspace not found")
    static let noteNotFound = String(localized: "rpc.note.error.noteNotFound", defaultValue: "Note not found")
    static let accessFailed = String(localized: "rpc.note.error.accessFailed", defaultValue: "I/O error while accessing the note")
    static let createFailed = String(localized: "rpc.note.error.createFailed", defaultValue: "Failed to create note file")
    static let focusSurfaceMissing = String(localized: "rpc.note.error.focusSurfaceMissing", defaultValue: "No focused surface to split")
    static let sourceSurfaceNotFound = String(localized: "rpc.note.error.sourceSurfaceNotFound", defaultValue: "Source surface not found")
    static let surfaceCreateFailed = String(localized: "rpc.note.error.surfaceCreateFailed", defaultValue: "Failed to create note surface")
    static let listFailed = String(localized: "rpc.note.error.listFailed", defaultValue: "Failed to list notes")
    static let pathFailed = String(localized: "rpc.note.error.pathFailed", defaultValue: "Failed to resolve note path")
    static let deleteFailed = String(localized: "rpc.note.error.deleteFailed", defaultValue: "Failed to delete note")
    static let remoteUnavailable = String(localized: "rpc.note.error.remoteUnavailable", defaultValue: "Notes are not available for remote workspaces")

    static func invalidDirection(_ direction: String) -> String {
        String(
            localized: "rpc.note.error.invalidDirection",
            defaultValue: "Invalid direction '\(direction)' (left|right|up|down)"
        )
    }
}

extension TerminalController {
    // MARK: - Notes

    func v2NoteCreate(params: [String: Any]) -> V2CallResult {
        let hasSlugParameter = params.keys.contains("slug")
        let providedSlug = v2String(params, "slug")
        let slug: String
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
            slug = NoteSupport.autoSlug()
        }
        return v2NoteOpenSplit(slug: slug, params: params, createIfMissing: true)
    }

    func v2NoteOpen(params: [String: Any]) -> V2CallResult {
        guard let rawSlug = v2String(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
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
    private func v2NoteOpenSplit(
        slug: String,
        params: [String: Any],
        createIfMissing: Bool
    ) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: NoteRPCMessage.tabManagerUnavailable, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.openFailed, data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: NoteRPCMessage.workspaceNotFound, data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            guard let projectRoot = ws.noteProjectRoot() else {
                result = .err(code: "unavailable", message: NoteRPCMessage.remoteUnavailable, data: nil)
                return
            }
            let notePath = NoteSupport.notePath(forSlug: slug, projectRoot: projectRoot)
            let fileExistedBeforeCall: Bool
            do {
                fileExistedBeforeCall = try NoteSupport.noteFileExists(forSlug: slug, projectRoot: projectRoot)
            } catch {
                terminalNoteLogger.error(
                    "Failed to inspect note slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                )
                result = .err(
                    code: "io_error",
                    message: NoteRPCMessage.accessFailed,
                    data: [
                        "slug": slug,
                        "path": notePath,
                        "project_root": projectRoot
                    ]
                )
                return
            }
            if !createIfMissing {
                guard fileExistedBeforeCall else {
                    result = .err(
                        code: "not_found",
                        message: NoteRPCMessage.noteNotFound,
                        data: ["slug": slug, "path": notePath, "project_root": projectRoot]
                    )
                    return
                }
            } else {
                do {
                    try NoteSupport.ensureNoteFile(slug: slug, projectRoot: projectRoot)
                } catch {
                    terminalNoteLogger.error(
                        "Failed to create note slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                    )
                    result = .err(
                        code: "io_error",
                        message: NoteRPCMessage.createFailed,
                        data: [
                            "slug": slug,
                            "path": notePath,
                            "project_root": projectRoot
                        ]
                    )
                    return
                }
            }
            // Open new (empty) notes directly in text-edit mode so the user
            // can start writing without clicking the mode toggle. Existing
            // notes with content default to preview (MarkdownPanel default).
            let openInTextMode = !fileExistedBeforeCall

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
            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let directionStr = v2String(params, "direction") ?? "right"
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
            let focusAllowed = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

            // Reuse an existing markdown panel that already shows this note,
            // so repeated `cmux note open <slug>` focuses rather than spawns
            // duplicates. Mirrors openOrFocusMarkdownSurface semantics.
            let canonical = (notePath as NSString).resolvingSymlinksInPath
            for (existingId, existingPanel) in ws.panels {
                guard let md = existingPanel as? MarkdownPanel else { continue }
                if (md.filePath as NSString).resolvingSymlinksInPath == canonical {
                    if focusAllowed {
                        ws.focusPanel(existingId)
                    }
                    let targetPaneUUID = ws.paneId(forPanelId: existingId)?.id
                    let windowId = v2ResolveWindowId(tabManager: tabManager)
                    result = .ok([
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
                        "slug": slug,
                        "path": notePath,
                        "project_root": projectRoot,
                        "reused": true
                    ])
                    return
                }
            }

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: notePath,
                focus: focusAllowed
            )

            guard let panel = createdPanel else {
                result = .err(code: "internal_error", message: NoteRPCMessage.surfaceCreateFailed, data: nil)
                return
            }
            if openInTextMode {
                panel.setDisplayMode(.text)
            }

            let targetPaneUUID = ws.paneId(forPanelId: panel.id)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
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
                "slug": slug,
                "path": notePath,
                "project_root": projectRoot,
                "reused": false
            ])
        }
        return result
    }

    func v2NoteList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: NoteRPCMessage.tabManagerUnavailable, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.listFailed, data: nil)
        var projectRoot: String?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: NoteRPCMessage.workspaceNotFound, data: nil)
                return
            }
            projectRoot = ws.noteProjectRoot()
            if projectRoot == nil {
                result = .err(code: "unavailable", message: NoteRPCMessage.remoteUnavailable, data: nil)
            }
        }
        guard let projectRoot else {
            return result
        }
        let entries = NoteSupport.listNotes(forProjectRoot: projectRoot)
        let payload: [[String: Any]] = entries.map { entry in
            [
                "slug": entry.slug,
                "path": entry.path,
                "size_bytes": entry.sizeBytes,
                "mtime": entry.mtime.timeIntervalSince1970
            ]
        }
        result = .ok([
            "project_root": projectRoot,
            "notes": payload
        ])
        return result
    }

    func v2NotePath(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: NoteRPCMessage.tabManagerUnavailable, data: nil)
        }
        guard let rawSlug = v2String(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.pathFailed, data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: NoteRPCMessage.workspaceNotFound, data: nil)
                return
            }
            guard let projectRoot = ws.noteProjectRoot() else {
                result = .err(code: "unavailable", message: NoteRPCMessage.remoteUnavailable, data: nil)
                return
            }
            let path = NoteSupport.notePath(forSlug: slug, projectRoot: projectRoot)
            let exists: Bool
            do {
                exists = try NoteSupport.noteFileExists(forSlug: slug, projectRoot: projectRoot)
            } catch {
                terminalNoteLogger.error(
                    "Failed to resolve note path slug=\(slug, privacy: .private) root=\(projectRoot, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                )
                result = .err(
                    code: "io_error",
                    message: NoteRPCMessage.accessFailed,
                    data: [
                        "slug": slug,
                        "path": path,
                        "project_root": projectRoot
                    ]
                )
                return
            }
            result = .ok([
                "slug": slug,
                "path": path,
                "exists": exists,
                "project_root": projectRoot
            ])
        }
        return result
    }

    func v2NoteDelete(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: NoteRPCMessage.tabManagerUnavailable, data: nil)
        }
        guard let rawSlug = v2String(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: NoteRPCMessage.missingSlug, data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: NoteRPCMessage.deleteFailed, data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: NoteRPCMessage.workspaceNotFound, data: nil)
                return
            }
            guard let projectRoot = ws.noteProjectRoot() else {
                result = .err(code: "unavailable", message: NoteRPCMessage.remoteUnavailable, data: nil)
                return
            }
            do {
                let deleted = try NoteSupport.deleteNote(slug: slug, projectRoot: projectRoot)
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
        }
        return result
    }
}
