import AppKit
import CmuxTestSupport

/// Opens a folder named in terminal output in Finder (cx-do47).
///
/// A folder is not a document for the configured editor: Cmd-click shows its
/// contents in Finder. A package (an `.app`, a `.bundle`) is a folder too,
/// but opening one would launch it, so Finder reveals it instead.
enum TerminalFolderOpener {
    /// Whether `path` names an existing folder.
    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Shows `path` in Finder: its contents, or the package selected.
    @MainActor
    static func open(_ path: String) {
        if UITestCaptureSink().appendLineIfConfigured(envKey: "CMUX_UI_TEST_CAPTURE_OPEN_FOLDER_PATH", line: path) {
            return
        }
        let workspace = NSWorkspace.shared
        if workspace.isFilePackage(atPath: path) {
            workspace.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            workspace.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }
}
