/// A synchronously readable mirror of the live worker's remote layer context.
@MainActor
public final class SimulatorRemoteContextCache {
    /// The current context identifier, or `nil` while no worker is presenting.
    public internal(set) var contextID: UInt32?

    /// Creates an empty context cache.
    public nonisolated init() {}
}
