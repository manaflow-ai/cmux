import Foundation
import Bonsplit

extension TerminalController {
    // MARK: - Notes

    func v2NoteCreate(params: [String: Any]) -> V2CallResult {
        let providedSlug = v2String(params, "slug")
        let slug: String
        if let providedSlug, !providedSlug.isEmpty {
            do {
                slug = try NoteSupport.validateSlug(providedSlug)
            } catch {
                return .err(code: "invalid_params", message: String(describing: error), data: nil)
            }
        } else {
            slug = NoteSupport.autoSlug()
        }
        return v2NoteOpenSplit(slug: slug, params: params, createIfMissing: true)
    }

    func v2NoteOpen(params: [String: Any]) -> V2CallResult {
        guard let rawSlug = v2String(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'slug' parameter", data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: String(describing: error), data: nil)
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
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to open note", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let projectRoot = ws.noteProjectRoot()
            let notePath = NoteSupport.notePath(forSlug: slug, projectRoot: projectRoot)
            let fileExistedBeforeCall = FileManager.default.fileExists(atPath: notePath)
            if !createIfMissing {
                guard fileExistedBeforeCall else {
                    result = .err(
                        code: "not_found",
                        message: "Note not found: \(slug)",
                        data: ["slug": slug, "path": notePath, "project_root": projectRoot]
                    )
                    return
                }
            } else {
                do {
                    try NoteSupport.ensureNoteFile(slug: slug, projectRoot: projectRoot)
                } catch {
                    result = .err(
                        code: "io_error",
                        message: "Failed to create note file",
                        data: [
                            "slug": slug,
                            "path": notePath,
                            "project_root": projectRoot,
                            "error_description": error.localizedDescription
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
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(
                    code: "not_found",
                    message: "Source surface not found",
                    data: ["surface_id": sourceSurfaceId.uuidString]
                )
                return
            }
            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let directionStr = v2String(params, "direction") ?? "right"
            guard let direction = parseSplitDirection(directionStr) else {
                result = .err(
                    code: "invalid_params",
                    message: "Invalid direction '\(directionStr)' (left|right|up|down)",
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
                result = .err(code: "internal_error", message: "Failed to create note surface", data: nil)
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
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to list notes", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let projectRoot = ws.noteProjectRoot()
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
        }
        return result
    }

    func v2NotePath(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawSlug = v2String(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'slug' parameter", data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: String(describing: error), data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to resolve note path", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let projectRoot = ws.noteProjectRoot()
            let path = NoteSupport.notePath(forSlug: slug, projectRoot: projectRoot)
            result = .ok([
                "slug": slug,
                "path": path,
                "exists": FileManager.default.fileExists(atPath: path),
                "project_root": projectRoot
            ])
        }
        return result
    }

    func v2NoteDelete(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawSlug = v2String(params, "slug"), !rawSlug.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'slug' parameter", data: nil)
        }
        let slug: String
        do {
            slug = try NoteSupport.validateSlug(rawSlug)
        } catch {
            return .err(code: "invalid_params", message: String(describing: error), data: nil)
        }
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to delete note", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let projectRoot = ws.noteProjectRoot()
            do {
                let deleted = try NoteSupport.deleteNote(slug: slug, projectRoot: projectRoot)
                result = .ok([
                    "slug": slug,
                    "deleted": deleted,
                    "project_root": projectRoot
                ])
            } catch {
                result = .err(
                    code: "io_error",
                    message: "Failed to delete note",
                    data: [
                        "slug": slug,
                        "project_root": projectRoot,
                        "error_description": error.localizedDescription
                    ]
                )
            }
        }
        return result
    }
}
