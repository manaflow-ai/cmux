/// Opaque lifecycle state retained by the broker while it replaces a failed tunnel.
public struct RemotePTYLifecycleSnapshot: Sendable {
    let registry: RemotePTYLifecycleRegistry

    /// Creates an empty snapshot for tunnel implementations without PTY lifecycle state.
    public init() {
        registry = RemotePTYLifecycleRegistry()
    }

    init(registry: RemotePTYLifecycleRegistry) {
        self.registry = registry
    }
}
