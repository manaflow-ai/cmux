import Foundation

/// The folders whose files a page may save (diff-host.md: files outside every workspace root are
/// read only). A root is a terminal folder's git top level, else the folder itself; never home
/// itself or `/`, which would make every file writable.
nonisolated struct FileWorkspaceRoots: Sendable, Equatable {
    /// Real paths, in the order first seen, without duplicates.
    let paths: [String]

    init(folders: [String], home: String = NSHomeDirectory()) {
        let excluded: Set<String> = ["/", Self.real(home)]
        var seen: Set<String> = []
        var paths: [String] = []
        for folder in folders where !folder.isEmpty {
            let real = Self.real(folder)
            let root = Self.repositoryRoot(containing: real, stopAt: excluded) ?? real
            guard !excluded.contains(root), seen.insert(root).inserted else { continue }
            paths.append(root)
        }
        self.paths = paths
    }

    /// Whether some root contains `path` (a real path, or one whose folder resolves).
    func contains(_ path: String) -> Bool {
        let real = Self.real(path)
        return paths.contains { real == $0 || real.hasPrefix($0 + "/") }
    }

    static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The nearest folder at or above `path` with a `.git` entry, below the excluded folders.
    private static func repositoryRoot(containing path: String, stopAt excluded: Set<String>) -> String? {
        var candidate = URL(fileURLWithPath: path, isDirectory: true)
        while !excluded.contains(candidate.path) {
            if FileManager.default.fileExists(atPath: candidate.appending(path: ".git").path) { return candidate.path }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
        return nil
    }
}
