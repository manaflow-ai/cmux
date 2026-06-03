/// A persistence seam for loading and saving the terminal store snapshot.
public protocol TerminalSnapshotPersisting {
    /// Loads the persisted snapshot, returning an empty snapshot when none exists.
    func load() -> TerminalStoreSnapshot
    /// Persists the given snapshot.
    /// - Parameter snapshot: The snapshot to save.
    /// - Throws: An error if the snapshot cannot be written.
    func save(_ snapshot: TerminalStoreSnapshot) throws
}
