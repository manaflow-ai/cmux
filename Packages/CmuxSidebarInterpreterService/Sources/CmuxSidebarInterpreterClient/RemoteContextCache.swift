/// Main-actor mirror of the supervised render worker's current remote context
/// id.
///
/// A freshly mounted sidebar surface reads this synchronously to adopt the
/// live worker's layer in the same frame it appears, instead of blanking for
/// the duration of the async ``RenderWorkerClient/subscribe()`` round-trip
/// (the stream replay still delivers the id, plus any later regenerations).
@MainActor
public final class RemoteContextCache {
    /// The live worker's context id, or `nil` while no worker is alive.
    public internal(set) var contextId: UInt32?

    /// Creates an empty cache; the owning client populates it.
    public nonisolated init() {}
}
