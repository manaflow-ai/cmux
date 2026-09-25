import Foundation
import os

nonisolated private let openFolderPanelStartDirectoryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "OpenFolderPanel"
)

/// Picks the folder the Open Folder panel starts in.
///
/// `app.defaultWorkspacePath` pins it (#3156). When that is empty or does
/// not name an existing directory, the panel starts in the active
/// workspace's directory, as before.
public struct OpenFolderPanelStartDirectory {
    public var homeDirectory: String
    public var isDirectory: (String) -> Bool

    public init(
        homeDirectory: String = NSHomeDirectory(),
        isDirectory: @escaping (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.homeDirectory = homeDirectory
        self.isDirectory = isDirectory
    }

    public func resolve(configuredPath: String, workspaceDirectory: String?) -> URL? {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let path = expandedPath(trimmed), isDirectory(path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            openFolderPanelStartDirectoryLogger.warning(
                "app.defaultWorkspacePath is not an existing folder; using the active workspace directory"
            )
        }
        if let workspaceDirectory, !workspaceDirectory.isEmpty {
            return URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        }
        return nil
    }

    /// Expands a leading `~`. Returns nil for a path that is not absolute
    /// after expansion.
    func expandedPath(_ path: String) -> String? {
        var expanded = path
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + String(expanded.dropFirst())
        }
        return expanded.hasPrefix("/") ? expanded : nil
    }
}
