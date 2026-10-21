import CmuxNextFiles
import Foundation

/// The seven file explorer actions on the explorer's selection (classic's
/// FileExplorerKeyboardShortcuts and its context menu). Open Selection
/// expands or collapses a folder and opens a file in cmux when cmux shows its
/// kind, else in its default app, as classic's Return and double-click did.
@MainActor
struct FileExplorerCommands {
    let model: FileExplorerModel
    let effects: any FileExplorerEffects

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
