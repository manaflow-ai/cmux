public import Foundation

/// The folders whose files a page may save besides the documents the user granted (coordinator
/// rule: only folders the USER chose, the `files.roots` setting). Nothing is inferred: no
/// terminal working directory, no repository top level, never home itself or `/`, which would
/// make every file writable.
public nonisolated struct FileWorkspaceRoots: Sendable, Equatable {
    /// Real paths, in the order given, without duplicates.
    public let paths: [String]

    /// Resolves only the supplied folders, excluding the filesystem root and home.
    ///
    /// - Parameters:
    ///   - folders: Folders chosen by the user.
    ///   - home: Home directory to exclude; tests may supply an isolated directory.
    public init(folders: [String], home: String = NSHomeDirectory()) {
        let excluded: Set<String> = ["/", Self.real(home)]
        var seen: Set<String> = []
        paths = folders.filter { !$0.isEmpty }.map(Self.real).filter { !excluded.contains($0) && seen.insert($0).inserted }
    }

    /// Whether some root contains `path` (links resolved first).
    public func contains(_ path: String) -> Bool {
        let real = Self.real(path)
        return paths.contains { real == $0 || real.hasPrefix($0 + "/") }
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
