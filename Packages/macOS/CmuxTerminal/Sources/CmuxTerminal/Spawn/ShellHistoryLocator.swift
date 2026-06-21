public import Foundation

/// Computes per-tab shell-history file locations under Application Support so a
/// terminal tab recovers its own command history (up-arrow / Ctrl-R) when it
/// reopens.
///
/// Files are keyed **only by the terminal surface id**, which session restore
/// reuses across restarts — so the exact tab finds the exact same file every
/// time. The working directory is deliberately *not* part of the key: a tab's
/// cwd is not stable between first open (often unset) and restore (the captured
/// directory), so hashing it into the path would send the restored tab to a
/// different, empty file and break ↑ recall. History is still per-tab (distinct
/// tabs get distinct files).
///
/// Layout:
/// - history:  `<AppSupport>/cmux/shell-history/<surface-uuid>.<ext>`
/// - commands: `<AppSupport>/cmux/shell-history/_commands/<surface-uuid>.commands.json`
///
/// Pure and dependency-injected (`appSupportDirectory`, `fileManager`) so it is
/// exercised directly by unit tests.
public enum ShellHistoryLocator {
    /// The shell-history root: `<AppSupport>/cmux/shell-history`.
    public static func rootDirectory(
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let base: URL?
        if let appSupportDirectory {
            base = appSupportDirectory
        } else {
            base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        }
        return base?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("shell-history", isDirectory: true)
    }

    /// The per-tab shell-history file: `<root>/<surface-uuid>.<ext>`.
    public static func historyFileURL(
        surfaceID: UUID,
        fileExtension: String,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        rootDirectory(appSupportDirectory: appSupportDirectory, fileManager: fileManager)?
            .appendingPathComponent("\(surfaceID.uuidString).\(fileExtension)", isDirectory: false)
    }

    /// The per-tab cmux command-history side file:
    /// `<root>/_commands/<surface-uuid>.commands.json`.
    public static func commandsFileURL(
        surfaceID: UUID,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        rootDirectory(appSupportDirectory: appSupportDirectory, fileManager: fileManager)?
            .appendingPathComponent("_commands", isDirectory: true)
            .appendingPathComponent("\(surfaceID.uuidString).commands.json", isDirectory: false)
    }
}
