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
        resolvedRootPath = Self.resolvedPath(root) ?? root.standardizedFileURL.path
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
    /// The target is resolved by hand rather than with `resolvingSymlinksInPath()`,
    /// which leaves a link whose target does not exist looking like the link's
    /// own path, so a dangling `gone -> /elsewhere/secret` read as inside the
    /// repository and was reproduced in the new worktree, where it becomes a live
    /// link out of the tree the moment the target appears.
    ///
    /// The comparison adds the separator so `/repo-backup` does not read as being
    /// inside `/repo`.
    private static func isInside(_ url: URL, resolvedRootPath: String) -> Bool {
        guard let resolved = resolvedPath(url) else { return false }
        if resolved == resolvedRootPath { return true }
        return resolved.hasPrefix(resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/")
    }

    /// The physical path of `url`, following every symlink along it, including
    /// a chain of links and links in the target's parents. Lookups stop at the
    /// first component that does not exist, and the rest is kept as written,
    /// so a dangling link still resolves to where it points.
    ///
    /// A `..` after a missing component returns `nil`. What it climbs out of
    /// is not known until that component exists: created later as a symlink,
    /// `future/../x` would leave the tree, so it cannot be judged inside now.
    ///
    /// The path is kept as components and normalized lexically. Foundation's
    /// path standardization is not purely lexical: it drops a leading `/private`
    /// on Darwin, which would turn `/private/var/...` back into the `/var/...`
    /// it was just resolved from. Also returns `nil` when a chain of links does
    /// not end within `maximumSymlinkResolutions`, which covers cycles and links
    /// that expand into themselves.
    private static func resolvedPath(_ url: URL) -> String? {
        var pending = url.path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var resolutions = 0
        var reachedMissingComponent = false
        while !pending.isEmpty {
            let component = pending.removeFirst()
            switch component {
            case "", ".":
                continue
            case "..":
                guard !reachedMissingComponent else { return nil }
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            default:
                break
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            guard !reachedMissingComponent,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                // Not a link here, so `fileExists` (which follows links) only
                // asks whether this component is present.
                if !reachedMissingComponent, !FileManager.default.fileExists(atPath: candidate) {
                    reachedMissingComponent = true
                }
                resolved.append(component)
                continue
            }
            resolutions += 1
            guard resolutions <= maximumSymlinkResolutions else { return nil }
            if destination.hasPrefix("/") { resolved.removeAll() }
            pending = destination.split(separator: "/").map(String.init) + pending
        }
        return "/" + resolved.joined(separator: "/")
    }
}
