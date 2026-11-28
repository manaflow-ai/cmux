/// Describes whether stopping a remote session retains or relinquishes its persistent daemon slot.
public enum RemoteRelayCleanupScope: Sendable {
    /// Stops only transient transport resources so the persistent PTY can reconnect.
    case transport

    /// Stops the persistent daemon and removes all state owned by the slot.
    case persistentSlot
}
