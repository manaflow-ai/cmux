import Foundation

/// The folders whose files a page may save besides the documents the user granted (coordinator
/// rule: only folders the USER chose, the `files.roots` setting). Nothing is inferred: no
/// terminal working directory, no repository top level, never home itself or `/`, which would
/// make every file writable.
nonisolated struct FileWorkspaceRoots: Sendable, Equatable {
    /// Real paths, in the order given, without duplicates.
    let paths: [String]

    init(folders: [String], home: String = NSHomeDirectory()) {
        let excluded: Set<String> = ["/", Self.real(home)]
        var seen: Set<String> = []
        paths = folders.filter { !$0.isEmpty }.map(Self.real).filter { !excluded.contains($0) && seen.insert($0).inserted }
    }

    /// Whether some root contains `path` (links resolved first).
    func contains(_ path: String) -> Bool {
        let real = Self.real(path)
        return paths.contains { real == $0 || real.hasPrefix($0 + "/") }
    }

    static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
