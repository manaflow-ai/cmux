public import Foundation

/// Selects live workspace UUIDs during session restore while preserving persisted
/// identities whenever they are safe to reuse.
public enum WorkspaceSessionRestoreIdentity {
    /// Returns the persisted workspace UUID unless the snapshot identity is
    /// excluded or the UUID has already been reserved in this restore batch.
    public static func restoredWorkspaceId(
        persistedWorkspaceId: UUID?,
        stableId: UUID?,
        reservedWorkspaceIds: inout Set<UUID>,
        excludingStableIdentities: Set<UUID> = []
    ) -> UUID {
        restoredWorkspaceId(
            persistedWorkspaceId: persistedWorkspaceId,
            reservedWorkspaceIds: &reservedWorkspaceIds,
            shouldExcludePersistedWorkspaceId: stableId.map {
                excludingStableIdentities.contains($0)
            } ?? false
        )
    }

    /// Returns the persisted workspace UUID unless the caller already knows it
    /// must be excluded or the UUID has already been reserved.
    public static func restoredWorkspaceId(
        persistedWorkspaceId: UUID?,
        reservedWorkspaceIds: inout Set<UUID>,
        shouldExcludePersistedWorkspaceId: Bool = false
    ) -> UUID {
        if !shouldExcludePersistedWorkspaceId,
           let persistedWorkspaceId,
           reservedWorkspaceIds.insert(persistedWorkspaceId).inserted {
            return persistedWorkspaceId
        }
        return freshWorkspaceId(reservingIn: &reservedWorkspaceIds)
    }

    /// Mints and reserves a UUID that is not already present in the provided set.
    public static func freshWorkspaceId(reservingIn reservedWorkspaceIds: inout Set<UUID>) -> UUID {
        var id = UUID()
        while !reservedWorkspaceIds.insert(id).inserted {
            id = UUID()
        }
        return id
    }
}
