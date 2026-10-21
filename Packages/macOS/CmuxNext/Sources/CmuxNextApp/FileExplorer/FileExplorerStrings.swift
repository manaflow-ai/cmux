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
