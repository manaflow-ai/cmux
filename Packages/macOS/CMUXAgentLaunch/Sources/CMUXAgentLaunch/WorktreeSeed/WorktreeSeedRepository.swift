import Foundation

/// Reads a `.worktreeinclude` and the directories its patterns reach.
///
/// This is the only part of seeding that touches the source repository, so it is
/// also where "inside the repository" is decided. `root` is resolved once, and a
/// child is reported as escaping when it is a symlink whose target resolves
    /// outside that resolved root.
public struct WorktreeSeedRepository: Sendable {
    /// The repository root, as given.
    public let root: URL
    private let resolvedRootPath: String
    private static let maximumSymlinkResolutions = 64

    /// Creates a reader for a repository root.
    public init(root: URL) {
        self.root = root
        resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The `.worktreeinclude` at the root, or `nil` when the repository has none.
    ///
    /// A missing file is not an error: most repositories will never have one, and
    /// seeding then does nothing.
    public func includeFile() throws -> WorktreeSeedFile? {
        let url = root.appendingPathComponent(WorktreeSeedFile.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return WorktreeSeedFile.parse(String(decoding: data, as: UTF8.self))
    }

    /// A planner that walks this repository.
    public func planner(maximumVisitedDirectories: Int = 20_000) -> WorktreeSeedPlanner {
        let resolvedRootPath = resolvedRootPath
        let root = root
        return WorktreeSeedPlanner(maximumVisitedDirectories: maximumVisitedDirectories) { relativeDirectory in
            WorktreeSeedRepository.listing(
                relativeDirectory,
                root: root,
                resolvedRootPath: resolvedRootPath
            )
        }
    }

    /// The children of a repository-relative directory. `""` is the root.
    public func listing(_ relativeDirectory: String) -> [WorktreeSeedListedEntry] {
        WorktreeSeedRepository.listing(relativeDirectory, root: root, resolvedRootPath: resolvedRootPath)
    }

    private static func listing(
        _ relativeDirectory: String,
        root: URL,
        resolvedRootPath: String
    ) -> [WorktreeSeedListedEntry] {
        let directory = relativeDirectory.isEmpty
            ? root
            : root.appendingPathComponent(relativeDirectory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().map { name in
            let child = directory.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = values?.isSymbolicLink ?? false
            return WorktreeSeedListedEntry(
                name: name,
                // A symlink is a leaf even when it points at a directory, which is
                // how git reads one too. The walk therefore never goes through a
                // symlink, so a link that points at its own ancestor cannot make
                // the walk loop, and a `build/` pattern does not match a symlink
                // named `build`. The link itself is still copyable or linkable.
                isDirectory: (values?.isDirectory ?? false) && !isSymbolicLink,
                escapesRepository: isSymbolicLink && !isInside(child, resolvedRootPath: resolvedRootPath)
            )
        }
    }

    /// Whether the symlink at `url` points to somewhere under the resolved
    /// repository root.
    ///
    /// The target is read and resolved by hand rather than by resolving the link
    /// itself. `resolvingSymlinksInPath()` leaves a link whose target does not
    /// exist looking like the link's own path, so a dangling
    /// `gone -> /elsewhere/secret` read as inside the repository and was
    /// reproduced in the new worktree, where it becomes a live link out of the
    /// tree the moment the target appears.
    ///
    /// The comparison adds the separator so `/repo-backup` does not read as being
    /// inside `/repo`.
    private static func isInside(_ url: URL, resolvedRootPath: String) -> Bool {
        guard let resolved = resolveSymlinksPreservingMissingLeaf(url)?.path else { return false }
        if resolved == resolvedRootPath { return true }
        return resolved.hasPrefix(resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/")
    }

    private static func resolveSymlinksPreservingMissingLeaf(_ url: URL) -> URL? {
        var current = url.standardizedFileURL
        var seen: Set<String> = []
        var resolutions = 0

        while true {
            guard seen.insert(current.path).inserted else { return nil }
            let components = current.pathComponents
            var rebuilt = URL(fileURLWithPath: components[0], isDirectory: true)
            var foundSymlink = false

            for (offset, component) in components.dropFirst().enumerated() {
                rebuilt.appendPathComponent(component)
                if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: rebuilt.path) {
                    guard resolutions < maximumSymlinkResolutions else { return nil }
                    resolutions += 1
                    current = URL(fileURLWithPath: destination, relativeTo: rebuilt.deletingLastPathComponent())
                    for suffix in components.dropFirst(offset + 2) {
                        current.appendPathComponent(suffix)
                    }
                    current = current.standardizedFileURL
                    foundSymlink = true
                    break
                }
            }

            if !foundSymlink { return rebuilt.standardizedFileURL }
        }
    }
}
