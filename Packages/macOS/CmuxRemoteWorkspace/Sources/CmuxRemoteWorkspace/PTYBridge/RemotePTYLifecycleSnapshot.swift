/// Opaque lifecycle state retained by the broker while it replaces a failed tunnel.
public struct RemotePTYLifecycleSnapshot: Sendable {
    var registry: RemotePTYLifecycleRegistry

    /// Creates an empty snapshot for tunnel implementations without PTY lifecycle state.
    public init() {
        registry = RemotePTYLifecycleRegistry()
    }

    init(registry: RemotePTYLifecycleRegistry) {
        self.registry = registry
    }

    mutating func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String) {
        registry.acknowledge(RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID))
    }

    mutating func acknowledgePTYLifecycleIfKnown(sessionID: String, lifecycleID: String) -> Bool {
        registry.acknowledgeIfKnown(RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID))
    }

    func ptySessionLifecycle(sessionID: String, lifecycleID: String) -> RemotePTYSessionLifecycle {
        registry.lifecycle(for: RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID))
    }
}
