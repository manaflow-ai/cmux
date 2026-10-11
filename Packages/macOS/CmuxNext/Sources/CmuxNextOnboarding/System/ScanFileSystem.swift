public import Foundation

/// The probes the project scans make of folders outside the agents' own data
/// folders: whether a path is a folder, whether it exists, its subfolders,
/// its modification date and where its symlinks lead. `live` is the disk; a
/// test passes a recording one to prove which paths a scan touches
/// (LAUNCH-NO-TCC-PROMPTS: never one inside a `PrivacyFolder`).
public nonisolated struct ScanFileSystem: Sendable {
    /// True for an existing folder that is not a symlink.
    public var isDirectory: @Sendable (String) -> Bool
    public var exists: @Sendable (String) -> Bool
    /// The names of a folder's subfolders, hidden ones and symlinks left out.
    public var subdirectories: @Sendable (URL) -> [String]
    public var modified: @Sendable (String) -> Date
    /// The path with every symlink on its way resolved (`lstat` and `readlink` only).
    public var resolve: @Sendable (String) -> String

    public init(isDirectory: @escaping @Sendable (String) -> Bool, exists: @escaping @Sendable (String) -> Bool,
                subdirectories: @escaping @Sendable (URL) -> [String], modified: @escaping @Sendable (String) -> Date,
                resolve: @escaping @Sendable (String) -> String) {
        self.isDirectory = isDirectory
        self.exists = exists
        self.subdirectories = subdirectories
        self.modified = modified
        self.resolve = resolve
    }

    public static let live = ScanFileSystem(
        isDirectory: { path in
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        },
        exists: { FileManager.default.fileExists(atPath: $0) },
        subdirectories: { directory in
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            return entries.compactMap { entry in
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                return entry.lastPathComponent
            }.sorted()
        },
        modified: { path in
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        },
        resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    )
}
