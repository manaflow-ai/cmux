import Foundation

/// A ``FileExplorerProvider`` backed by the local filesystem.
///
/// Lists directories via `FileManager` on the machine running the app. It is
/// always available and reports the current user's home directory, so the file
/// explorer can show local workspaces without any connection setup.
public final class LocalFileExplorerProvider: FileExplorerProvider {
    /// The current user's home directory.
    public var homePath: String { NSHomeDirectory() }
    /// Always `true`; the local filesystem is always reachable.
    public var isAvailable: Bool { true }

    /// Creates a local filesystem provider.
    public init() {}

    /// Lists the children of `path`, skipping dotfiles unless `showHidden` is set.
    public func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)
        return contents.compactMap { name in
            guard showHidden || !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileExplorerEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
        }
    }
}
