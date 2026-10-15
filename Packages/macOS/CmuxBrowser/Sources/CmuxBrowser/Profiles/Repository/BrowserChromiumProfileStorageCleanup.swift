public import Foundation

/// Removes the Chromium stores of deleted browser profiles.
///
/// Chromium keeps an opened request context's files until the process ends,
/// so a deleted profile's `Profile-<UUID>` directory is removed right away
/// only when Chromium has not opened it in this process; otherwise it stays
/// on a persisted pending list and goes at the next launch, before Chromium
/// starts. The list is explicit: a directory is never removed just because
/// the profile list lacks it (a profile list that failed to decode would
/// otherwise wipe every profile's data).
@MainActor
public final class BrowserChromiumProfileStorageCleanup {
    /// `UserDefaults` key for the pending profile ids.
    public static let pendingDefaultsKey = "browserProfiles.chromiumPendingCleanup.v1"

    public let storage: BrowserChromiumProfileStorage
    private let defaults: UserDefaults

    /// Creates the cleanup.
    /// - Parameters:
    ///   - storage: The Chromium profile storage.
    ///   - defaults: Backing store for the pending list.
    public init(storage: BrowserChromiumProfileStorage, defaults: UserDefaults) {
        self.storage = storage
        self.defaults = defaults
    }

    /// Profile ids whose Chromium store still waits for removal.
    public var pendingProfileIDs: [UUID] {
        (defaults.stringArray(forKey: Self.pendingDefaultsKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Records a deleted profile. The built-in default is never removed.
    /// - Parameter profileID: The deleted profile's id.
    public func markDeleted(_ profileID: UUID) {
        guard profileID != BrowserProfileRepository.builtInDefaultProfileID else { return }
        var pending = pendingProfileIDs
        guard !pending.contains(profileID) else { return }
        pending.append(profileID)
        save(pending)
    }

    /// The store directories of pending profiles Chromium has not opened in
    /// this process, for ``removeDirectories(_:fileManager:)``. A profile stays
    /// pending until its directory is gone, so a crash between this call and
    /// the deletion never orphans a store: the next call (at the latest, the
    /// next launch) finds it again.
    /// - Parameter isOpened: Whether Chromium opened the profile in this process.
    /// - Returns: Store directories to remove.
    public func takeRemovable(isOpened: (UUID) -> Bool, fileManager: FileManager = .default) -> [URL] {
        let pending = pendingProfileIDs
        var keep: [UUID] = []
        var removable: [URL] = []
        for id in pending {
            let directory = storage.cachePath(forProfileID: id)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            keep.append(id)
            if !isOpened(id) { removable.append(directory) }
        }
        if keep != pending { save(keep) }
        return removable
    }

    /// Deletes store directories (missing ones are fine). Each directory is
    /// first renamed aside so a Chromium start racing the deletion never
    /// reopens a half-deleted store. Call off the main thread.
    /// - Parameter directories: Directories from ``takeRemovable(isOpened:)``.
    public nonisolated static func removeDirectories(_ directories: [URL], fileManager: FileManager = .default) {
        for directory in directories {
            let aside = directory.deletingLastPathComponent()
                .appendingPathComponent(".deleted-\(UUID().uuidString)", isDirectory: true)
            if (try? fileManager.moveItem(at: directory, to: aside)) != nil {
                try? fileManager.removeItem(at: aside)
            }
        }
    }

    /// Deletes Chromium's cache directories of a profile Chromium has not
    /// opened in this process (an opened one clears its cache through
    /// Chromium). Each is renamed aside under the root first, so an
    /// interrupted deletion is finished by ``removeLeftovers(in:fileManager:)``.
    /// Call off the main thread.
    /// - Returns: Whether any cache directory existed.
    @discardableResult
    public nonisolated static func removeCaches(
        ofProfileID profileID: UUID,
        in storage: BrowserChromiumProfileStorage,
        fileManager: FileManager = .default
    ) -> Bool {
        var removed = false
        for directory in storage.cacheDirectories(forProfileID: profileID) {
            let aside = storage.root.appendingPathComponent(".cleared-\(UUID().uuidString)", isDirectory: true)
            guard (try? fileManager.moveItem(at: directory, to: aside)) != nil else { continue }
            removed = true
            try? fileManager.removeItem(at: aside)
        }
        return removed
    }

    /// Renames items aside under the root (`.deleted-*`), so they leave their
    /// profile at once; ``deleteAside(_:fileManager:)`` deletes them later and
    /// ``removeLeftovers(in:fileManager:)`` finishes an interrupted deletion.
    ///
    /// Renaming is quick and atomic, so a caller on the main actor (where
    /// Chromium opens profiles) checks that Chromium has not opened a profile
    /// and moves its files aside in one turn, leaving no window in which a page
    /// could open the files being deleted. Missing items are skipped.
    /// - Returns: The renamed locations.
    public nonisolated static func moveAside(
        _ items: [URL],
        in storage: BrowserChromiumProfileStorage,
        fileManager: FileManager = .default
    ) -> [URL] {
        items.compactMap { item in
            let aside = storage.root.appendingPathComponent(".deleted-\(UUID().uuidString)", isDirectory: false)
            return (try? fileManager.moveItem(at: item, to: aside)) != nil ? aside : nil
        }
    }

    /// Deletes items ``moveAside(_:in:fileManager:)`` renamed. Call off the main thread.
    public nonisolated static func deleteAside(_ items: [URL], fileManager: FileManager = .default) {
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }

    /// Deletes directories a previous run renamed aside but did not finish
    /// deleting (`.deleted-*` profile stores, `.cleared-*` caches) directly
    /// under the root. Call off the main thread, before Chromium starts.
    public nonisolated static func removeLeftovers(in storage: BrowserChromiumProfileStorage, fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: storage.root.path) else { return }
        for name in names where name.hasPrefix(".deleted-") || name.hasPrefix(".cleared-") {
            try? fileManager.removeItem(at: storage.root.appendingPathComponent(name, isDirectory: true))
        }
    }

    private func save(_ ids: [UUID]) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.pendingDefaultsKey)
        } else {
            defaults.set(ids.map(\.uuidString), forKey: Self.pendingDefaultsKey)
        }
    }
}
