import AppKit
import CmuxNextDesign
import CmuxNextFiles
import CmuxNextFilesUI
import Foundation

/// The seven file explorer actions on the explorer's selection (classic's
/// FileExplorerKeyboardShortcuts and its context menu). Open Selection
/// expands or collapses a folder and opens a file in cmux when cmux shows its
/// kind, else in its default app, as classic's Return and double-click did.
/// New File, New Folder, Rename and Move to Trash (the explorer's menu) change
/// the folder through ``FileOperating`` and list it again.
@MainActor
struct FileExplorerCommands {
    let model: FileExplorerModel
    let effects: any FileExplorerEffects
    var files: any FileOperating
    /// The window's undo stack: Move to Trash puts its Put Back there (Edit > Undo, Cmd-Z).
    var undoManager: UndoManager?

    /// `files` defaults to the effects' (the app's files lane).
    init(model: FileExplorerModel, effects: any FileExplorerEffects, files: (any FileOperating)? = nil,
         undoManager: UndoManager? = nil) {
        self.model = model
        self.effects = effects
        self.files = files ?? effects.files
        self.undoManager = undoManager
    }

    /// Makes an empty "untitled" file (numbered when taken) where the selection is and selects it.
    @discardableResult
    func newFile() async throws -> URL {
        let folder = await targetFolder()
        let file = try await files.newFile(in: folder, named: FileExplorerStrings.untitledFile, contents: Data())
        await model.reload()
        model.selection = file.standardizedFileURL
        return file
    }

    /// Makes an "untitled folder" (numbered when taken) where the selection is and selects it.
    @discardableResult
    func newFolder() async throws -> URL {
        let folder = await targetFolder()
        let made = try await files.newFolder(in: folder, named: FileExplorerStrings.untitledFolder)
        await model.reload()
        model.selection = made.standardizedFileURL
        return made
    }

    /// Renames `item` to `name` in its folder and keeps it selected.
    @discardableResult
    func rename(_ item: URL, to name: String) async throws -> URL {
        let renamed = try await files.rename(item, to: name)
        await model.reload()
        model.selection = renamed.standardizedFileURL
        return renamed
    }

    /// Moves the selected item to the Trash.
    func moveToTrash() async throws {
        let row = try selected()
        let trashed = try await files.trash([row.url])
        model.selection = nil
        await model.reload()
        let files = files, model = model
        // Edit > Undo (Cmd-Z) puts the item back where it was and selects it, as Finder's Put Back.
        ToastUndoStep.attach(title: FileExplorerStrings.undoMoveToTrash, filling: nil, undoManager: undoManager, handle: nil) {
            // task-owner: one Put Back and a relisting; ends when the folder lists again.
            // main-hop-allow: the person's Undo, userBlocking rest (p06 rule 2): Put Back is FileOperating's off-main move, then the model's main-actor async relisting
            Task { @MainActor in
                guard let back = try? await files.putBack(trashed) else { return }
                await model.reload()
                model.selection = back.first?.standardizedFileURL
            }
        }
    }

    /// Where a new item goes: in the selected folder (expanded to show it), else beside the
    /// selected item, else in the root.
    private func targetFolder() async -> URL {
        guard let row = model.selectedRow else { return model.root ?? FileManager.default.homeDirectoryForCurrentUser }
        if row.isFolder {
            await model.expand(row.url)
            return row.url
        }
        return row.url.deletingLastPathComponent()
    }

    /// Return and Cmd-Down (Finder's Open): a folder expands or collapses, a file opens.
    func openSelection() async throws {
        let row = try selected()
        if row.isFolder {
            await model.toggle(row.url)
        } else if !effects.openInCmux(row.url) {
            effects.openInDefaultApp(row.url)
        }
    }

    /// Open in cmux: a file cmux shows opens beside the focused pane.
    func openInCmux() throws {
        let row = try selected()
        guard !row.isFolder, effects.openInCmux(row.url) else { throw FileExplorerError.notViewable(row.name) }
    }

    /// Open as Text: the selected file's source in the code editor.
    func openAsText() throws {
        let row = try selected()
        guard !row.isFolder, effects.openAsText(row.url) else { throw FileExplorerError.notViewable(row.name) }
    }

    func revealInFinder() throws {
        effects.revealInFinder(try selected().url)
    }

    func copyPath() throws {
        effects.copy(try selected().url.path)
    }

    func copyRelativePath() throws {
        effects.copy(model.relativePath(of: try selected().url))
    }

    func open(withApp app: String) async throws {
        try await effects.open(try selected().url, withApp: app)
    }

    private func selected() throws -> FileExplorerRow {
        guard let row = model.selectedRow else { throw FileExplorerError.noSelection }
        return row
    }
}
