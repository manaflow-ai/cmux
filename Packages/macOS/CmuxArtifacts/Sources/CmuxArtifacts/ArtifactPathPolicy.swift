import Darwin
import Foundation

/// Explicit path-containment and privacy checks used before any file read.
public struct ArtifactPathPolicy: Sendable {
    /// Path components that commonly contain credentials or private keys.
    public let sensitiveComponents: Set<String>

    /// Creates a path policy with conservative sensitive-component defaults.
    public init(sensitiveComponents: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".kube", ".config/gcloud", ".netrc", ".npmrc",
        ".env", ".env.local", "credentials", "credential", "secrets", "private.key", "gcloud",
    ]) {
        self.sensitiveComponents = sensitiveComponents.map { $0.lowercased() }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Canonicalizes a path lexically and resolves existing symlink components.
    public func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Returns whether a path is a descendant of one of the explicit roots.
    public func isContained(_ url: URL, in roots: [URL]) -> Bool {
        let candidate = canonicalURL(url).path
        return roots.contains { root in
            let rootPath = canonicalURL(root).path
            return candidate == rootPath || candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    /// Returns whether an automatic capture path contains a sensitive component.
    public func isSensitive(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        return components.contains { component in
            sensitiveComponents.contains(component) || component.hasPrefix(".env.")
        }
    }

    /// Returns true when any existing component is a symbolic link.
    ///
    /// This lexical check happens before canonicalization so an automatic
    /// capture cannot turn a symlink swap into an apparently contained path.
    public func hasSymlinkComponent(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents where component != "/" {
            current.appendPathComponent(component, isDirectory: false)
            var status = stat()
            guard lstat(current.path, &status) == 0 else { continue }
            if (status.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    /// Returns whether the final path entry itself is a symbolic link.
    ///
    /// System locations such as `/var` are legitimate intermediate symlinks on
    /// macOS, so callers that need to reject an imported file should inspect
    /// the final entry separately rather than rejecting every ancestor.
    public func hasFinalSymlink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.standardizedFileURL.path, &status) == 0
            && (status.st_mode & S_IFMT) == S_IFLNK
    }

    /// Returns a safe relative path when a path is inside a root.
    public func relativePath(of url: URL, under root: URL) -> String? {
        let candidate = canonicalURL(url).path
        let rootPath = canonicalURL(root).path
        guard candidate != rootPath,
              candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            return nil
        }
        return String(candidate.dropFirst(rootPath.count + 1))
    }
}
