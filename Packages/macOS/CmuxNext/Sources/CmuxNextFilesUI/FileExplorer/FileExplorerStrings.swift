package import Foundation

/// The file explorer's and the Find section's text. Keys live in
/// Resources/FileExplorer.xcstrings.
package nonisolated struct FileExplorerStrings {
    package nonisolated init() {}
    /// The bundle that holds `Resources/FileExplorer.xcstrings` (this module's), for tests.
    package static var bundle: Bundle { .module }
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "FileExplorer", bundle: .module)
    }

    package static var noSelection: String { text("fileExplorer.noSelection", "Select a file or folder in the file explorer first.") }
    package static func notViewable(_ name: String) -> String {
        String(format: text("fileExplorer.notViewable", "cmux cannot show “%@”."), name)
    }
    package static func noSuchApp(_ app: String) -> String {
        String(format: text("fileExplorer.noSuchApp", "No app named “%@” is installed."), app)
    }
    package static func openFailed(_ name: String) -> String {
        String(format: text("fileExplorer.openFailed", "“%@” could not be opened."), name)
    }
    package static var noFolder: String { text("fileExplorer.noFolder", "No folder") }
    package static var noExplorer: String { text("fileExplorer.noExplorer", "Show Files in the right sidebar first.") }
    package static var openInCmux: String { text("fileExplorer.menu.openInCmux", "Open in cmux") }
    package static var revealInFinder: String { text("fileExplorer.menu.revealInFinder", "Reveal in Finder") }
    package static var copyPath: String { text("fileExplorer.menu.copyPath", "Copy Path") }
    package static var copyRelativePath: String { text("fileExplorer.menu.copyRelativePath", "Copy Relative Path") }
    package static var openWithSubmenu: String { text("fileExplorer.menu.openWithSubmenu", "Open With") }
    package static var openWithOther: String { text("fileExplorer.menu.openWithOther", "Other…") }
    package static var loadingApps: String { text("fileExplorer.menu.loadingApps", "Loading…") }
    package static var openPrompt: String { text("fileExplorer.openPrompt", "Open") }
    /// An Open With row for the file's default app.
    package static func defaultApp(_ name: String) -> String {
        String(format: text("fileExplorer.menu.defaultApp", "%@ (default)"), name)
    }
    /// The Other… panel's message.
    package static func chooseApp(_ name: String) -> String {
        String(format: text("fileExplorer.chooseApp", "Choose an app to open “%@”."), name)
    }
    /// The name of a new file and folder (numbered when taken), as Finder names them.
    package static var untitledFile: String { text("fileExplorer.untitledFile", "untitled") }
    package static var untitledFolder: String { text("fileExplorer.untitledFolder", "untitled folder") }
    /// The undo step's name (Edit > Undo Move to Trash).
    package static var undoMoveToTrash: String { text("fileExplorer.undo.moveToTrash", "Move to Trash") }
    /// The accessibility description of a row's git badge.
    package static func gitState(_ state: FileGitState) -> String {
        switch state {
        case .modified: text("fileExplorer.git.modified", "Modified")
        case .added: text("fileExplorer.git.added", "Added")
        case .deleted: text("fileExplorer.git.deleted", "Deleted")
        case .renamed: text("fileExplorer.git.renamed", "Renamed")
        case .untracked: text("fileExplorer.git.untracked", "Untracked")
        case .conflicted: text("fileExplorer.git.conflicted", "Conflicted")
        case .containsChanges: text("fileExplorer.git.containsChanges", "Contains changes")
        }
    }
    package static var findPlaceholder: String { text("find.placeholder", "Find in Folder") }
    package static var findTitle: String { text("find.title", "Find") }
    /// The status line while ripgrep runs over `folder`.
    package static func searching(_ folder: String) -> String {
        String(format: text("find.searching", "Searching %@…"), folder)
    }
    package static func matchCount(_ count: Int) -> String {
        String(format: text("find.matchCount", "Matches: %lld"), count)
    }
}
