public import Foundation

/// Persists bounded workspace identity recovery records by workspace identity.
///
/// The session snapshot remains the baseline. This journal records immediate
/// title and user mutations so a quit before the next autosave cannot lose a
/// rename, recolor, or explicit clear.
@MainActor
public struct WorkspaceCustomizationStore {
    /// Production key for the stable-workspace-ID recovery journal.
    public nonisolated static let defaultStorageKey = "workspaceCustomizations.v2"

    /// Directory-keyed data written by older cmux versions.
    public nonisolated static let defaultLegacyStorageKey =
        WorkspaceDirectoryCustomizationStore.defaultStorageKey

    /// Maximum number of most-recently-mutated workspaces retained.
    public nonisolated static let defaultCapacity = 512

    private let defaults: UserDefaults?
    private let storageKey: String
    private let legacyStorageKey: String
    private let capacity: Int
    /// Nonisolated so a workspace owner can synchronously hand off pending
    /// records from its deinitializer without retaining the owner.
    private nonisolated let synchronousWriter: WorkspaceCustomizationSynchronousWriter

    /// Creates a store backed by the supplied defaults suite.
    ///
    /// Passing `nil` creates a no-op store for callers that do not need durable
    /// customization recovery.
    ///
    /// - Parameters:
    ///   - defaults: The defaults suite that owns the recovery journal.
    ///   - storageKey: The key under which the stable-ID journal is encoded.
    ///   - legacyStorageKey: The key containing directory-keyed data to migrate.
    ///   - capacity: The maximum number of workspace identities retained.
    public init(
        defaults: UserDefaults? = nil,
        storageKey: String = WorkspaceCustomizationStore.defaultStorageKey,
        legacyStorageKey: String = WorkspaceCustomizationStore.defaultLegacyStorageKey,
        capacity: Int = WorkspaceCustomizationStore.defaultCapacity
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyStorageKey = legacyStorageKey
        self.capacity = max(1, capacity)
        self.synchronousWriter = WorkspaceCustomizationSynchronousWriter(
            defaults: defaults,
            storageKey: storageKey,
            capacity: max(1, capacity)
        )
    }

    /// Persists automatic title records synchronously from a nonisolated owner
    /// teardown. The writer owns the lock and the complete snapshot transaction.
    public nonisolated func persistPendingAutomaticTitlesSynchronously(
        _ pending: [WorkspaceCustomizationPendingAutomaticTitle]
    ) {
        synchronousWriter.persistPendingAutomaticTitles(pending)
    }

    /// Reads the recovery record for one stable workspace identity.
    ///
    /// - Parameter stableId: The stable workspace identity.
    /// - Returns: The recorded customization, or `nil` when none exists.
    public func customization(for stableId: UUID) -> WorkspaceCustomization? {
        loadSnapshot().entries[stableId.uuidString]?.customization
    }

    /// Reads the monotonic title mutation revision for one stable workspace identity.
    /// A caller can use this as a fence for deferred writes that must not
    /// overwrite a later mutation made by another manager instance.
    public func customizationTitleMutationRevision(for stableId: UUID) -> UInt64? {
        loadSnapshot().entries[stableId.uuidString]?.titleMutationRevision
    }

    /// Reads the recovery value and its title-mutation fence from one snapshot.
    ///
    /// Automatic title notifications use this combined read because decoding
    /// the complete journal is synchronous. Keeping the two fields together
    /// avoids decoding the journal twice for one high-frequency notification.
    public func customizationAndTitleMutationRevision(
        for stableId: UUID
    ) -> (customization: WorkspaceCustomization, titleMutationRevision: UInt64)? {
        guard let entry = loadSnapshot().entries[stableId.uuidString] else { return nil }
        return (entry.customization, entry.titleMutationRevision)
    }

    /// Reads a batch of recovery records with one defaults decode.
    ///
    /// - Parameter stableIds: The stable workspace identities to read.
    /// - Returns: The available recovery records keyed by stable identity.
    public func customizations(for stableIds: [UUID]) -> [UUID: WorkspaceCustomization] {
        let requested = Set(stableIds)
        guard !requested.isEmpty else { return [:] }
        let entries = loadSnapshot().entries
        return Dictionary(uniqueKeysWithValues: requested.compactMap { stableId in
            entries[stableId.uuidString].map { (stableId, $0.customization) }
        })
    }

    /// Records the latest workspace-title mutation.
    ///
    /// - Parameters:
    ///   - title: The title to record, or `nil` to record an explicit clear.
    ///   - source: Whether the title came from a user or automatic naming.
    ///   - stableId: The stable workspace identity.
    public func setCustomTitle(
        _ title: String?,
        for stableId: UUID,
        source: WorkspaceCustomizationTitleSource = .user
    ) {
        let field = normalizedTitleField(title, source: source)
        updateTitleCustomization(for: stableId) { current in
            WorkspaceCustomization(
                customTitle: field,
                customColor: current?.customColor ?? .absent
            )
        }
    }

    /// Records the latest explicit workspace-color mutation.
    ///
    /// - Parameters:
    ///   - color: The color to record, or `nil` to record an explicit clear.
    ///   - stableId: The stable workspace identity.
    public func setCustomColor(_ color: String?, for stableId: UUID) {
        setCustomColor(color, for: [stableId])
    }

    /// Records one color mutation for several independent workspaces.
    ///
    /// - Parameters:
    ///   - color: The color to record, or `nil` to record an explicit clear.
    ///   - stableIds: The stable workspace identities to update.
    public func setCustomColor(_ color: String?, for stableIds: [UUID]) {
        let keys = Set(stableIds.map(\.uuidString))
        guard !keys.isEmpty else { return }
        let field = normalizedField(color)
        updateCustomizations(forKeys: keys) { current in
            WorkspaceCustomization(
                customTitle: current?.customTitle ?? .absent,
                customColor: field
            )
        }
    }

    /// Promotes unambiguous legacy directory records, then removes all v1 data.
    ///
    /// Callers provide only directories that map to exactly one restored
    /// workspace across the complete restore set. Ambiguous and orphaned
    /// directory records are deliberately discarded.
    ///
    /// - Parameter stableIdByDirectory: Unambiguous legacy directory owners.
    public func migrateLegacyDirectoryCustomizations(
        toStableIdsByDirectory stableIdByDirectory: [String: UUID]
    ) {
        guard let defaults else { return }
        let legacyStore = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: legacyStorageKey,
            capacity: capacity
        )
        let legacy = legacyStore.customizations(
            forDirectories: Array(stableIdByDirectory.keys)
        )
        for (directory, stableId) in stableIdByDirectory {
            guard let normalizedDirectory = legacyStore.directoryKey(for: directory),
                  let customization = legacy[normalizedDirectory] else {
                continue
            }
            updateCustomization(for: stableId) { current in
                WorkspaceCustomization(
                    customTitle: current?.customTitle == .absent || current == nil
                        ? self.migratedField(customization.customTitle)
                        : current?.customTitle ?? .absent,
                    customColor: current?.customColor == .absent || current == nil
                        ? self.migratedField(customization.customColor)
                        : current?.customColor ?? .absent
                )
            }
        }
        defaults.removeObject(forKey: legacyStorageKey)
    }

    /// Normalizes a legacy workspace root solely for v1 migration matching.
    ///
    /// - Parameter directory: A legacy workspace root path.
    /// - Returns: The normalized migration key, or `nil` for a blank path.
    public func legacyDirectoryKey(for directory: String?) -> String? {
        WorkspaceDirectoryCustomizationStore().directoryKey(for: directory)
    }

    @discardableResult
    private func updateCustomization(
        for stableId: UUID,
        _ transform: (WorkspaceCustomization?) -> WorkspaceCustomization
    ) -> WorkspaceCustomization {
        var result = WorkspaceCustomization()
        updateCustomizations(forKeys: [stableId.uuidString]) { current in
            result = transform(current)
            return result
        }
        return result
    }

    @discardableResult
    private func updateTitleCustomization(
        for stableId: UUID,
        _ transform: (WorkspaceCustomization?) -> WorkspaceCustomization
    ) -> WorkspaceCustomization {
        var result = WorkspaceCustomization()
        synchronousWriter.updateSnapshot { snapshot in
            result = transform(snapshot.entries[stableId.uuidString]?.customization)
            snapshot.setTitle(result, for: stableId.uuidString)
        }
        return result
    }

    private func updateCustomizations(
        forKeys keys: Set<String>,
        transform: (WorkspaceCustomization?) -> WorkspaceCustomization
    ) {
        synchronousWriter.updateSnapshot { snapshot in
            for key in keys.sorted() {
                snapshot.set(transform(snapshot.entries[key]?.customization), for: key)
            }
        }
    }

    private func normalizedField(_ value: String?) -> WorkspaceCustomizationField {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? .cleared : .value(trimmed)
    }

    private func normalizedTitleField(
        _ value: String?,
        source: WorkspaceCustomizationTitleSource
    ) -> WorkspaceCustomizationField {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .cleared }
        return source == .auto ? .autoValue(trimmed) : .value(trimmed)
    }

    private func migratedField(_ value: String?) -> WorkspaceCustomizationField {
        value.map(WorkspaceCustomizationField.value) ?? .cleared
    }

    private func loadSnapshot() -> WorkspaceCustomizationPersistenceSnapshot {
        synchronousWriter.loadSnapshot()
    }
}
