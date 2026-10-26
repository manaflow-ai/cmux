import CmuxNextFiles
import Foundation

/// What the file explorer's actions do outside the explorer: open in cmux or
/// another app, reveal in Finder, copy text, change files. ``AppFileExplorerEffects`` in the
/// App, a recorder in tests.
@MainActor
protocol FileExplorerEffects: AnyObject, Sendable {
    /// Opens `file` in cmux beside the focused pane, the code editor's cursor at `position` (a Find
    /// result; nil: the top); false when cmux shows no viewer for its kind.
    func openInCmux(_ file: URL, at position: FilePosition?) -> Bool
    /// Opens `file`'s text in the code editor beside the focused pane (Open as Text); false when
    /// it did not open.
    func openAsText(_ file: URL) -> Bool
    /// Opens `item` in its default app (a folder in Finder).
    func openInDefaultApp(_ item: URL)
    /// Selects `item` in a Finder window.
    func revealInFinder(_ item: URL)
    /// Puts `text` on the general pasteboard.
    func copy(_ text: String)
    /// Opens `item` with the app named by `app` (a bundle id, an app path or an app name).
    func open(_ item: URL, withApp app: String) async throws
    /// New File, New Folder, Rename and Move to Trash: the file changes, on the app's files lane.
    var files: any FileOperating { get }
}

extension FileExplorerEffects {
    /// Opens `file` in cmux at its top (``openInCmux(_:at:)``).
    func openInCmux(_ file: URL) -> Bool { openInCmux(file, at: nil) }
}
