import CmuxNextActions
import Foundation
import CmuxNextFilesUI

/// The tree an explorer action runs on, and what the run needs from its window.
struct FileExplorerRunTarget {
    let model: FileExplorerModel
    /// The window's undo stack (Move to Trash puts its Put Back there).
    var undoManager: UndoManager?
    /// Edits an item's name in its row (Rename, and a new item's first name).
    var rename: @MainActor (URL) -> Void = { _ in }
}

/// The file explorer's actions (Open Selection, Open Selection (Finder Style),
/// Open in cmux, Open as Text, Reveal in Finder, Copy Path, Copy Relative Path, Open With…,
/// New File, New Folder, Rename, Move to Trash): keys, the explorer's own menu,
/// the palette and `cmux action run` all run these on an explorer's selection:
/// the right-clicked tree for a row's menu (its `explorer` argument), else the
/// active window's. They need `fileExplorerFocused`, which the explorer's list
/// publishes while it has the keyboard (its right-click menu implies it). Work
/// is tracked, so a CLI run answers with its failure.
enum FileExplorerHandlers {
    static func bind(into registry: ActionRegistry, explorer: @escaping @MainActor (ActionInvocation) -> FileExplorerRunTarget?,
                     effects: any FileExplorerEffects) {
        func work(_ id: ActionID, _ body: @escaping @MainActor (ActionInvocation, FileExplorerCommands, FileExplorerRunTarget) async throws -> Void) {
            registry.bind(id, run: { invocation in
                guard let target = explorer(invocation) else { throw ActionFailure(message: FileExplorerStrings.noExplorer) }
                var commands = FileExplorerCommands(model: target.model, effects: effects)
                commands.undoManager = target.undoManager
                // task-owner: the action run; a capturing caller (CLI, MCP) awaits it through the registry.
                registry.track(Task { @MainActor in
                    do {
                        try await body(invocation, commands, target)
                        return nil
                    } catch {
                        let reason = Self.reason(error)
                        registry.refuse(reason)
                        return ActionWorkFailure(refusal: .unavailable, reason: reason)
                    }
                })
            })
        }
        func command(_ id: ActionID, _ body: @escaping @MainActor (FileExplorerCommands) async throws -> Void) {
            work(id) { _, commands, _ in try await body(commands) }
        }
        command("fileExplorerOpenSelection") { try await $0.openSelection() }
        command("fileExplorerOpenSelectionFinderAlias") { try await $0.openSelection() }
        command("fileExplorerOpenInCmux") { try $0.openInCmux() }
        command("fileExplorerOpenAsText") { try $0.openAsText() }
        command("fileExplorerReveal") { try $0.revealInFinder() }
        command("fileExplorerCopyPath") { try $0.copyPath() }
        command("fileExplorerCopyRelativePath") { try $0.copyRelativePath() }
        work("fileExplorerOpenWith") { invocation, commands, _ in
            guard let app = invocation["app"]?.stringValue, !app.isEmpty else {
                // No app (the menu's Other…): the person picks one, for the file the panel was opened for.
                // A script cannot answer a panel, so its run is refused.
                guard invocation.origin == .user else { throw FileExplorerError.noSuchApp("") }
                guard let row = commands.model.selectedRow else { throw FileExplorerError.noSelection }
                let item = row.url
                FileExplorerOpenWithMenu.chooseApp(for: item) { app in
                    // task-owner: one open with the chosen app; ends when the app has the file.
                    Task { @MainActor in
                        do { try await effects.open(item, withApp: app) } catch { registry.refuse(Self.reason(error)) }
                    }
                }
                return
            }
            try await commands.open(withApp: app)
        }
        work("fileExplorerNewFile") { _, commands, target in target.rename(try await commands.newFile()) }
        work("fileExplorerNewFolder") { _, commands, target in target.rename(try await commands.newFolder()) }
        work("fileExplorerRename") { _, commands, target in
            guard let row = commands.model.selectedRow else { throw FileExplorerError.noSelection }
            target.rename(row.url)
        }
        command("fileExplorerMoveToTrash") { try await $0.moveToTrash() }
    }

    private static func reason(_ error: any Error) -> String {
        (error as? FileExplorerError)?.reason ?? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
