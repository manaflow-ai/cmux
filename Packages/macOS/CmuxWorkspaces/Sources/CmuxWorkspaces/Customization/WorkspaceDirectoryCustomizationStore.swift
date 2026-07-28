public import Foundation

/// Persists bounded user-owned workspace identity independently from live workspace lifetimes.
///
/// `UserDefaults` is the sole source of truth. The store deliberately keeps no
/// in-memory mirror, so independently constructed window graphs cannot drift.
@MainActor
public struct WorkspaceDirectoryCustomizationStore {
    /// The production defaults key for the versioned directory snapshot.
    public nonisolated static let defaultStorageKey = "workspaceDirectoryCustomizations.v1"

    /// The maximum number of most-recently-mutated workspace roots retained.
    public nonisolated static let defaultCapacity = 512

    private let defaults: UserDefaults?
    private let storageKey: String
    private let capacity: Int

    /// Creates a store backed by the supplied defaults suite.
    ///
    /// Passing `nil` creates a no-op store, which is the default for isolated
    /// `TabManager` tests that do not exercise durable customization.
    ///
    /// - Parameters:
    ///   - defaults: The defaults suite that owns the directory map.
    ///   - storageKey: The key under which the encoded map is stored.
    ///   - capacity: The maximum retained roots, including explicit-clear tombstones.
    public init(
        defaults: UserDefaults? = nil,
        storageKey: String = WorkspaceDirectoryCustomizationStore.defaultStorageKey,
        capacity: Int = WorkspaceDirectoryCustomizationStore.defaultCapacity
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.capacity = max(1, capacity)
    }

    /// Returns the normalized stable key for a workspace root directory.
    ///
    /// - Parameter directory: A workspace root path.
    /// - Returns: A standardized, canonically composed path, or `nil` for a blank path.
    public func directoryKey(for directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
            .precomposedStringWithCanonicalMapping
        return standardized.isEmpty ? nil : standardized
    }

    /// Reads the sticky identity for a workspace root directory.
    ///
    /// - Parameter directory: A workspace root path or an already normalized key.
    /// - Returns: The stored customization, or `nil` when none exists.
    public func customization(for directory: String?) -> WorkspaceDirectoryCustomization? {
        guard let key = directoryKey(for: directory) else { return nil }
        return loadSnapshot().entries[key]?.customization
    }

    /// Reads sticky identity for a batch of workspace roots with one defaults decode.
    ///
    /// Returned keys are normalized directory paths. Explicit-clear tombstones
    /// remain present in the result.
    ///
    /// - Parameter directories: Workspace root paths or already normalized keys.
    /// - Returns: Stored customizations for the requested valid directories.
    public func customizations(
        forDirectories directories: [String]
    ) -> [String: WorkspaceDirectoryCustomization] {
        let keys = Set(directories.compactMap { directoryKey(for: $0) })
        guard !keys.isEmpty else { return [:] }
        let entries = loadSnapshot().entries
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            entries[key].map { (key, $0.customization) }
        })
    }

    /// Persists or clears the explicit label for a workspace root.
    ///
    /// - Parameters:
    ///   - title: The label to persist; blank text clears the label.
    ///   - directory: The workspace root directory.
    public func setCustomTitle(_ title: String?, for directory: String?) {
        let normalizedTitle = normalizedValue(title)
        updateCustomization(for: directory) { current in
            WorkspaceDirectoryCustomization(
                customTitle: normalizedTitle,
                customColor: current?.customColor
            )
        }
    }

    /// Persists or clears the explicit color for a workspace root.
    ///
    /// - Parameters:
    ///   - color: The color to persist; blank text clears the color.
    ///   - directory: The workspace root directory.
    public func setCustomColor(_ color: String?, for directory: String?) {
        guard let directory else { return }
        setCustomColor(color, forDirectories: [directory])
    }

    /// Persists or clears one explicit color across multiple workspace roots.
    ///
    /// The directory map is read and written once for the whole user action.
    ///
    /// - Parameters:
    ///   - color: The color to persist; blank text clears the color.
    ///   - directories: The workspace root directories to update.
    public func setCustomColor(_ color: String?, forDirectories directories: [String]) {
        let keys = Set(directories.compactMap { directoryKey(for: $0) })
        guard !keys.isEmpty else { return }
        let normalizedColor = normalizedValue(color)
        updateCustomizations(forKeys: keys) { current in
            WorkspaceDirectoryCustomization(
                customTitle: current?.customTitle,
                customColor: normalizedColor
            )
        }
    }

    /// Atomically updates both sticky identity fields for one workspace root.
    ///
    /// The transform receives the current value and its result becomes the
    /// complete record. An empty customization remains as an explicit-clear
    /// tombstone so stale session/history snapshots cannot resurrect it.
    ///
    /// - Parameters:
    ///   - directory: The workspace root directory.
    ///   - transform: A synchronous mutation of the current customization.
    /// - Returns: The normalized stored value, or `nil` when the directory is invalid.
    @discardableResult
    public func updateCustomization(
        for directory: String?,
        _ transform: (WorkspaceDirectoryCustomization?) -> WorkspaceDirectoryCustomization
    ) -> WorkspaceDirectoryCustomization? {
        guard let key = directoryKey(for: directory) else { return nil }
        var result: WorkspaceDirectoryCustomization?
        updateCustomizations(forKeys: [key]) { current in
            let customization = transform(current)
            let normalized = WorkspaceDirectoryCustomization(
                customTitle: normalizedValue(customization.customTitle),
                customColor: normalizedValue(customization.customColor)
            )
            result = normalized
            return normalized
        }
        return result
    }

    private func updateCustomizations(
        forKeys keys: Set<String>,
        transform: (WorkspaceDirectoryCustomization?) -> WorkspaceDirectoryCustomization
    ) {
        var snapshot = loadSnapshot()
        for key in keys.sorted() {
            let customization = transform(snapshot.entries[key]?.customization)
            snapshot.set(
                WorkspaceDirectoryCustomization(
                    customTitle: normalizedValue(customization.customTitle),
                    customColor: normalizedValue(customization.customColor)
                ),
                for: key
            )
        }
        snapshot.trim(to: capacity)
        persist(snapshot)
    }

    private func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadSnapshot() -> WorkspaceDirectoryCustomizationPersistenceSnapshot {
        guard let data = defaults?.data(forKey: storageKey) else {
            return WorkspaceDirectoryCustomizationPersistenceSnapshot()
        }
        let decoder = JSONDecoder()
        var snapshot: WorkspaceDirectoryCustomizationPersistenceSnapshot
        var shouldRewrite = false
        if let decoded = try? decoder.decode(
            WorkspaceDirectoryCustomizationPersistenceSnapshot.self,
            from: data
        ), decoded.version == WorkspaceDirectoryCustomizationPersistenceSnapshot.currentVersion {
            snapshot = decoded
        } else if let legacy = try? decoder.decode(
            [String: WorkspaceDirectoryCustomization].self,
            from: data
        ) {
            snapshot = WorkspaceDirectoryCustomizationPersistenceSnapshot(migrating: legacy)
            shouldRewrite = true
        } else {
            snapshot = WorkspaceDirectoryCustomizationPersistenceSnapshot()
        }
        let previousCount = snapshot.entries.count
        snapshot.trim(to: capacity)
        if shouldRewrite || snapshot.entries.count != previousCount {
            persist(snapshot)
        }
        return snapshot
    }

    private func persist(_ snapshot: WorkspaceDirectoryCustomizationPersistenceSnapshot) {
        guard let defaults else { return }
        guard !snapshot.entries.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
