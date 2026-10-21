import Foundation

/// The file explorer's and the Find section's text. Keys live in
/// Resources/FileExplorer.xcstrings.
nonisolated enum FileExplorerStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "FileExplorer", bundle: .module)
    }

    static var noSelection: String { text("fileExplorer.noSelection", "Select a file or folder in the file explorer first.") }
    static func notViewable(_ name: String) -> String {
        String(format: text("fileExplorer.notViewable", "cmux cannot show “%@”."), name)
    }
    static func noSuchApp(_ app: String) -> String {
        String(format: text("fileExplorer.noSuchApp", "No app named “%@” is installed."), app)
    }
    static func openFailed(_ name: String) -> String {
        String(format: text("fileExplorer.openFailed", "“%@” could not be opened."), name)
    }
    static var noFolder: String { text("fileExplorer.noFolder", "No folder") }
    static var noExplorer: String { text("fileExplorer.noExplorer", "Show Files in the right sidebar first.") }
    static var openInCmux: String { text("fileExplorer.menu.openInCmux", "Open in cmux") }
    static var revealInFinder: String { text("fileExplorer.menu.revealInFinder", "Reveal in Finder") }
    static var copyPath: String { text("fileExplorer.menu.copyPath", "Copy Path") }
    static var copyRelativePath: String { text("fileExplorer.menu.copyRelativePath", "Copy Relative Path") }
    static var openWith: String { text("fileExplorer.menu.openWith", "Open With…") }
    static var openWithSubmenu: String { text("fileExplorer.menu.openWithSubmenu", "Open With") }
    static var openWithOther: String { text("fileExplorer.menu.openWithOther", "Other…") }
    static var loadingApps: String { text("fileExplorer.menu.loadingApps", "Loading…") }
    static var openPrompt: String { text("fileExplorer.openPrompt", "Open") }
    /// An Open With row for the file's default app.
    static func defaultApp(_ name: String) -> String {
        String(format: text("fileExplorer.menu.defaultApp", "%@ (default)"), name)
    }
    /// The Other… panel's message.
    static func chooseApp(_ name: String) -> String {
        String(format: text("fileExplorer.chooseApp", "Choose an app to open “%@”."), name)
    }
    /// The name of a new file and folder (numbered when taken), as Finder names them.
    static var untitledFile: String { text("fileExplorer.untitledFile", "untitled") }
    static var untitledFolder: String { text("fileExplorer.untitledFolder", "untitled folder") }
    static var newFile: String { text("fileExplorer.menu.newFile", "New File") }
    static var newFolder: String { text("fileExplorer.menu.newFolder", "New Folder") }
    static var rename: String { text("fileExplorer.menu.rename", "Rename") }
    /// The undo step's name (Edit > Undo Move to Trash).
    static var undoMoveToTrash: String { text("fileExplorer.undo.moveToTrash", "Move to Trash") }
    static var moveToTrash: String { text("fileExplorer.menu.moveToTrash", "Move to Trash") }
    /// The accessibility description of a row's git badge.
    static func gitState(_ state: FileGitState) -> String {
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
    static var findPlaceholder: String { text("find.placeholder", "Find in Folder") }
    static var findTitle: String { text("find.title", "Find") }
    /// The status line while ripgrep runs over `folder`.
    static func searching(_ folder: String) -> String {
        String(format: text("find.searching", "Searching %@…"), folder)
    }
    static func matchCount(_ count: Int) -> String {
        String(format: text("find.matchCount", "Matches: %lld"), count)
    }
}
