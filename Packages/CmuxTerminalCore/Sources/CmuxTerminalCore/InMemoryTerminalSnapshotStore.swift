/// An in-memory ``TerminalSnapshotPersisting`` useful for tests and previews.
public final class InMemoryTerminalSnapshotStore: TerminalSnapshotPersisting {
    private var snapshot: TerminalStoreSnapshot

    /// Creates an in-memory snapshot store.
    /// - Parameter snapshot: The initial snapshot (defaults to ``TerminalStoreSnapshot/seed()``).
    public init(snapshot: TerminalStoreSnapshot = .seed()) {
        self.snapshot = snapshot
    }

    /// Returns the in-memory snapshot.
    public func load() -> TerminalStoreSnapshot {
        snapshot
    }

    /// Replaces the in-memory snapshot.
    /// - Parameter snapshot: The snapshot to store.
    public func save(_ snapshot: TerminalStoreSnapshot) throws {
        self.snapshot = snapshot
    }
}
