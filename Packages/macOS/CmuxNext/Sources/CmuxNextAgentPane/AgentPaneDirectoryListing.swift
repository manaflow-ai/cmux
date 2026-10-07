import Foundation

/// A directory listing returned to the keyboard-first project picker.
public nonisolated struct AgentPaneDirectoryListing: Equatable, Sendable {
    public let path: String
    public let parent: String?
    public let home: String
    public let directories: [String]

    public nonisolated enum Failure: Error, Equatable, Sendable {
        case invalidPath
        case outsideRoots
        case unreadable
        case notDirectory
    }

    /// Lists only readable child directories under one of the pane's canonical workspace roots.
    /// Symlinks are resolved before both the root check and the child result, so a link cannot
    /// escape the pane's scope. Dot-prefixed children stay hidden unless a user types their path.
    public static func list(path text: String, roots: [String], home: String = NSHomeDirectory()) -> Result<Self, Failure> {
        guard !text.isEmpty, text.utf8.count <= 4096, !text.utf8.contains(0) else { return .failure(.invalidPath) }
        let expanded: String
        if text == "~" || text.hasPrefix("~/") {
            expanded = home + String(text.dropFirst())
        } else if text.hasPrefix("/") {
            expanded = text
        } else {
            return .failure(.invalidPath)
        }

        guard let canonical = AcpmuxPathPolicy.canonical(expanded) else { return .failure(.unreadable) }
        guard AcpmuxPathPolicy.isDirectory(canonical) else { return .failure(.notDirectory) }
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        guard let root = canonicalRoots
            .filter({ AcpmuxPathPolicy.contains(root: $0, path: canonical) })
            .max(by: { $0.count < $1.count }) else {
            return .failure(.outsideRoots)
        }
        guard FileManager.default.isReadableFile(atPath: canonical) else { return .failure(.unreadable) }

        let homePath = AcpmuxPathPolicy.canonical(home) ?? home
        let parent: String?
        if canonical == root {
            parent = nil
        } else {
            let candidate = (canonical as NSString).deletingLastPathComponent
            parent = AcpmuxPathPolicy.contains(root: root, path: candidate) ? candidate : nil
        }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: canonical) else {
            return .failure(.unreadable)
        }
        let children = names.compactMap { name -> String? in
            guard !name.hasPrefix(".") else { return nil }
            let child = (canonical as NSString).appendingPathComponent(name)
            guard let resolved = AcpmuxPathPolicy.canonical(child),
                  AcpmuxPathPolicy.contains(root: root, path: resolved),
                  AcpmuxPathPolicy.isDirectory(resolved),
                  FileManager.default.isReadableFile(atPath: resolved) else { return nil }
            return resolved
        }.sorted()
        return .success(Self(path: canonical, parent: parent, home: homePath, directories: children))
    }
}
