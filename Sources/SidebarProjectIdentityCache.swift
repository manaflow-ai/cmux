import Foundation
import CmuxProjectIdentity

/// Main-actor cache of resolved ``ProjectIdentity`` values, keyed by project
/// root path and invalidated when the project root directory's mtime changes.
///
/// The read path is split so it is safe to call from a SwiftUI `body`:
/// ``cachedIdentity(forProjectRoot:)`` is a pure lookup (no side effects), while
/// ``requestIdentity(forProjectRoot:)`` schedules off-main resolution and must be
/// driven from a lifecycle hook (e.g. `.task`/`.onAppear`), never from `body`.
/// A completed resolution publishes through `@Observable`, triggering a re-render.
@MainActor
@Observable
final class SidebarProjectIdentityCache {
    private struct Entry {
        let identity: ProjectIdentity
        let mtime: Date?
    }

    private let resolver: ProjectIdentityResolver
    private let fileManager: FileManager
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    /// Creates a cache with the given resolver and file manager.
    ///
    /// - Parameters:
    ///   - resolver: The `ProjectIdentityResolver` used for off-main resolution.
    ///   - fileManager: Injected `FileManager`; defaults to `.default`.
    init(resolver: ProjectIdentityResolver, fileManager: FileManager = .default) {
        self.resolver = resolver
        self.fileManager = fileManager
    }

    /// Pure read: returns the cached identity for `root`, or `nil` if none has
    /// resolved yet. Does no file I/O and schedules no work, so it is safe to
    /// call from a SwiftUI `body`. A stale value (after the project root changed)
    /// is returned as-is so the UI degrades gracefully until a refresh lands.
    func cachedIdentity(forProjectRoot root: String) -> ProjectIdentity? {
        entries[root]?.identity
    }

    /// Schedules off-main resolution for `root` when no fresh entry is cached.
    ///
    /// Drive this from a lifecycle hook (`.task`/`.onAppear`), never from `body`.
    /// A no-op when a fresh (matching-mtime) entry already exists or a resolution
    /// is already in flight. The completed value publishes through `@Observable`.
    func requestIdentity(forProjectRoot root: String) {
        let currentMtime = appIconMTime(forProjectRoot: root)
        if let entry = entries[root], entry.mtime == currentMtime {
            return  // already fresh
        }
        scheduleResolve(root: root, mtime: currentMtime)
    }

    /// Test seam: resolves, stores, and returns the identity — awaitable by callers.
    @discardableResult
    func resolvedIdentity(forProjectRoot root: String) async -> ProjectIdentity {
        let mtime = appIconMTime(forProjectRoot: root)
        let identity = await resolver.resolve(projectRootPath: root)
        entries[root] = Entry(identity: identity, mtime: mtime)
        return identity
    }

    // MARK: - Private

    private func scheduleResolve(root: String, mtime: Date?) {
        guard !inFlight.contains(root) else { return }
        inFlight.insert(root)
        Task { @MainActor in
            let identity = await resolver.resolve(projectRootPath: root)
            entries[root] = Entry(identity: identity, mtime: mtime)
            inFlight.remove(root)
        }
    }

    private func appIconMTime(forProjectRoot root: String) -> Date? {
        // Use the project root dir mtime as a cheap staleness key.
        // AppIcon edits bump an ancestor directory's mtime on save, which is
        // good enough to invalidate the cached identity.
        let attrs = try? fileManager.attributesOfItem(atPath: root)
        return attrs?[.modificationDate] as? Date
    }
}
