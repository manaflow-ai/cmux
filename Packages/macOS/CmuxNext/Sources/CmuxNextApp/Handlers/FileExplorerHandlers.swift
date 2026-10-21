import CmuxNextActions
import Foundation

/// The file explorer's actions (Open Selection, Open Selection (Finder Style),
/// Open in cmux, Reveal in Finder, Copy Path, Copy Relative Path, Open With…,
/// New File, New Folder, Rename, Move to Trash): keys, the explorer's own menu,
/// the palette and `cmux sidebar ...` all run these on the active window's
/// explorer selection. They need `fileExplorerFocused`, which the explorer's
/// list publishes while it has the keyboard (its right-click menu implies it).
/// Work is tracked, so a CLI run answers with its failure.
enum FileExplorerHandlers {
    /// - Parameter rename: Edits an item's name in its row (Rename, and a new item's first name).
    static func bind(into registry: ActionRegistry, explorer: @escaping @MainActor () -> FileExplorerModel?,
                     effects: any FileExplorerEffects, rename: @escaping @MainActor (URL) -> Void = { _ in }) {
        func work(_ id: ActionID, _ body: @escaping @MainActor (ActionInvocation, FileExplorerCommands) async throws -> Void) {
            registry.bind(id, run: { invocation in
                guard let model = explorer() else { throw ActionFailure(message: FileExplorerStrings.noExplorer) }
                let commands = FileExplorerCommands(model: model, effects: effects)
                // task-owner: the action run; a capturing caller (CLI, MCP) awaits it through the registry.
                registry.track(Task { @MainActor in
                    do {
                        try await body(invocation, commands)
                        return nil
                    } catch {
                        let reason = (error as? FileExplorerError)?.reason ?? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        registry.refuse(reason)
                        return ActionWorkFailure(refusal: .unavailable, reason: reason)
                    }
                })
            })
        }
        work("fileExplorerOpenSelection") { try await $1.openSelection() }
        work("fileExplorerOpenSelectionFinderAlias") { try await $1.openSelection() }
        work("fileExplorerOpenInCmux") { try $1.openInCmux() }
        work("fileExplorerReveal") { try $1.revealInFinder() }
        work("fileExplorerCopyPath") { try $1.copyPath() }
        work("fileExplorerCopyRelativePath") { try $1.copyRelativePath() }
        work("fileExplorerOpenWith") { invocation, commands in
            guard let app = invocation["app"]?.stringValue, !app.isEmpty else {
                // No app (the menu's Other…): the person picks one, then the same action runs with it.
                guard let row = commands.model.selectedRow else { throw FileExplorerError.noSelection }
                FileExplorerOpenWithMenu.chooseApp(for: row.url) { app in
                    var chosen = invocation
                    chosen.arguments["app"] = .string(app)
                    registry.perform("fileExplorerOpenWith", invocation: chosen)
                }
                return
            }
            try await commands.open(withApp: app)
        }
        work("fileExplorerNewFile") { rename(try await $1.newFile()) }
        work("fileExplorerNewFolder") { rename(try await $1.newFolder()) }
        work("fileExplorerRename") { _, commands in
            guard let row = commands.model.selectedRow else { throw FileExplorerError.noSelection }
            rename(row.url)
        }
        work("fileExplorerMoveToTrash") { try await $1.moveToTrash() }
    }
}
