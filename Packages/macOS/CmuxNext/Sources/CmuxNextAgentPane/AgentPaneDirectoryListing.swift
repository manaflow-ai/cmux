import Foundation

/// A directory listing returned to the keyboard-first project picker.
nonisolated struct AgentPaneDirectoryListing: Equatable, Sendable {
    let path: String
    let parent: String?
    let home: String
    let directories: [String]

    nonisolated enum Failure: Error, Equatable, Sendable {
        case invalidPath
        case outsideRoots
        case unreadable
        case notDirectory
    }

    /// Credential stores are never exposed by the read-only picker. Dot folders are filtered
    /// below as a general UI rule, while this list also blocks direct requests for known stores.
    private static let credentialFolders = [
        ".ssh", ".gnupg", ".aws", ".azure", ".docker", ".config/gh", ".config/gcloud",
        "Library/Keychains", "Library/Application Support/Keychains",
    ]

    private static func isCredentialPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        for folder in credentialFolders {
            let denied = folder.lowercased().split(separator: "/")
            guard denied.count <= components.count else { continue }
            for start in 0...(components.count - denied.count) {
                if Array(components[start..<(start + denied.count)]) == denied { return true }
            }
        }
        return false
    }

    /// Lists only readable child directories under one of the read-only browser roots.
    /// Symlinks are resolved before both the root check and the child result, so a link cannot
    /// escape the pane's scope. Dot-prefixed children stay hidden unless a user types their path.
    static func list(path text: String, roots: [String], home: String = NSHomeDirectory()) -> Result<Self, Failure> {
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
        guard !isCredentialPath(canonical) else { return .failure(.unreadable) }
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        guard canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: canonical) }) else {
            return .failure(.outsideRoots)
        }
        guard FileManager.default.isReadableFile(atPath: canonical) else { return .failure(.unreadable) }

        let homePath = AcpmuxPathPolicy.canonical(home) ?? home
        let parent: String?
        let candidate = (canonical as NSString).deletingLastPathComponent
        parent = canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: candidate) }) ? candidate : nil

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: canonical) else {
            return .failure(.unreadable)
        }
        let children = names.compactMap { name -> String? in
            guard !name.hasPrefix(".") else { return nil }
            let child = (canonical as NSString).appendingPathComponent(name)
            guard let resolved = AcpmuxPathPolicy.canonical(child),
                  canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: resolved) }),
                  !isCredentialPath(resolved),
                  AcpmuxPathPolicy.isDirectory(resolved),
                  FileManager.default.isReadableFile(atPath: resolved) else { return nil }
            return resolved
        }.sorted()
        return .success(Self(path: canonical, parent: parent, home: homePath, directories: children))
    }
}
