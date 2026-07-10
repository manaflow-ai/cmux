/// A synchronously readable mirror of the live worker's remote layer context.
@MainActor
public final class SimulatorRemoteContextCache {
    private var latestRevision: UInt64 = 0

    /// The current context identifier, or `nil` while no worker is presenting.
    public internal(set) var contextID: UInt32?

    /// Creates an empty context cache.
    public nonisolated init() {}

    func update(contextID: UInt32?, revision: UInt64) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        self.contextID = contextID
    }
}
