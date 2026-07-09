import Bonsplit
import Foundation
import os

nonisolated private let workspaceLogger = Logger(subsystem: "com.cmuxterm.app", category: "workspace")

extension Workspace {
    // MARK: - Notes

    /// Open (or focus) a project-scoped note as a surface in the given pane.
    /// Internally this is a `MarkdownPanel` — the "note" distinction lives at
    /// the storage convention and at the `CmuxSurfaceType.note` public surface
    /// type. Note metadata lives in `<project>/.cmux/notes/index.json`; legacy
    /// `.cmux/notes/<slug>.md` files are still opened through the same store.
    @MainActor @discardableResult
    func newNoteSurface(
        inPane paneId: PaneID,
        slug: String,
        createIfMissing: Bool = true,
        focus: Bool? = nil,
        reuseExisting: Bool = true
    ) async -> MarkdownPanel? {
        await openOrCreateNoteSurface(
            inPane: paneId,
            slug: slug,
            title: nil,
            attachment: nil,
            createIfMissing: createIfMissing,
            focus: focus,
            reuseExisting: reuseExisting,
            preferAttachedExisting: false
        )
    }

    @MainActor @discardableResult
    func openAttachedNoteForSurface(
        inPane paneId: PaneID,
        panelId: UUID,
        focus: Bool = true,
        requireTerminal: Bool = false
    ) async -> MarkdownPanel? {
        guard let attachment = noteAttachmentTargetForPanel(
            panelId: panelId,
            requireTerminal: requireTerminal
        ) else {
            return nil
        }
        // "New Note" mirrors `cmux note new`: every invocation creates a fresh
        // auto-slug note rather than reopening the surface's existing note. The
        // attachment is still recorded for provenance, but we never prefer or
        // reuse an already-attached note — otherwise repeated New Note actions
        // (and the case where the prior note was dragged to another pane) would
        // just refocus the existing note instead of creating another one.
        // Surface-scoped notes open as a RIGHT SPLIT of the source surface
        // (the CLI's `cmux note new` default), keeping the conversation and
        // its note side by side instead of burying the note as a tab.
        return await openOrCreateNoteSurface(
            inPane: paneId,
            slug: nil,
            title: nil,
            attachment: attachment,
            createIfMissing: true,
            focus: focus,
            reuseExisting: false,
            preferAttachedExisting: false,
            splitFromPanelId: panelId
        )
    }

    @MainActor @discardableResult
    func openAttachedNoteForWorkspace(
        inPane paneId: PaneID,
        focus: Bool = true
    ) async -> MarkdownPanel? {
        // See `openAttachedNoteForSurface`: New Note always creates a fresh note
        // instead of refocusing the workspace's existing note.
        await openOrCreateNoteSurface(
            inPane: paneId,
            slug: nil,
            title: nil,
            attachment: noteAttachmentTargetForWorkspace(),
            createIfMissing: true,
            focus: focus,
            reuseExisting: false,
            preferAttachedExisting: false
        )
    }

    @MainActor @discardableResult
    func openOrCreateNoteSurface(
        inPane paneId: PaneID,
        slug: String?,
        title: String? = nil,
        attachment: CmuxNoteAttachmentTarget? = nil,
        createIfMissing: Bool = true,
        focus: Bool? = nil,
        reuseExisting: Bool = true,
        preferAttachedExisting: Bool = false,
        splitFromPanelId: UUID? = nil
    ) async -> MarkdownPanel? {
        let workspaceCurrentDirectory = currentDirectory
        let workspaceIsRemote = isRemoteWorkspace
        guard let root = await Self.noteProjectRootOffMain(
            currentDirectory: workspaceCurrentDirectory,
            isRemoteWorkspace: workspaceIsRemote
        ) else {
            workspaceLogger.error("Note surfaces are not available for remote workspaces")
            return nil
        }
        let noteResult: CmuxNoteStoreResult
        do {
            noteResult = try await Self.createOrOpenNoteOffMain(
                slug: slug,
                title: title,
                projectRoot: root,
                createIfMissing: createIfMissing,
                attachment: attachment,
                preferAttachedExisting: preferAttachedExisting
            )
        } catch {
            workspaceLogger.error(
                "Failed to open note surface slug=\(slug ?? "nil", privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            return nil
        }

        let filePath = noteResult.path
        if reuseExisting {
            let panel = openOrFocusMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus ?? false)
            panel?.markAsProjectNote(
                slug: noteResult.note.slug,
                id: noteResult.note.id,
                bodyPath: noteResult.note.bodyPath,
                title: noteResult.note.title
            )
            panel?.setDisplayMode(.text, focusTextEditor: focus ?? false)
            return panel
        }
        let panel: MarkdownPanel?
        if let splitFromPanelId {
            // Right split of the source surface (matches `cmux note new`).
            panel = newMarkdownSplit(
                from: splitFromPanelId,
                orientation: .horizontal,
                filePath: filePath,
                focus: focus ?? false
            ) ?? newMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus)
        } else {
            panel = newMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus)
        }
        panel?.markAsProjectNote(
            slug: noteResult.note.slug,
            id: noteResult.note.id,
            bodyPath: noteResult.note.bodyPath,
            title: noteResult.note.title
        )
        panel?.setDisplayMode(.text, focusTextEditor: focus ?? false)
        return panel
    }

    private nonisolated static func createOrOpenNoteOffMain(
        slug: String?,
        title: String?,
        projectRoot: String,
        createIfMissing: Bool,
        attachment: CmuxNoteAttachmentTarget?,
        preferAttachedExisting: Bool
    ) async throws -> CmuxNoteStoreResult {
        try await CmuxNoteStore.createOrOpenAsync(
            slug: slug,
            title: title,
            projectRoot: projectRoot,
            createIfMissing: createIfMissing,
            attachment: attachment,
            preferAttachedExisting: preferAttachedExisting
        )
    }

    private nonisolated static func noteProjectRootOffMain(
        currentDirectory: String,
        isRemoteWorkspace: Bool
    ) async -> String? {
        guard !isRemoteWorkspace else { return nil }
        return await NoteSupport.projectRootAsync(forCwd: currentDirectory)
    }

}
