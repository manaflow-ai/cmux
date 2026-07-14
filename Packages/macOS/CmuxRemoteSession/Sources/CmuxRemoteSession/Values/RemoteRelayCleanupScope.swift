/// Distinguishes transient relay transport cleanup from final slot ownership teardown.
enum RemoteRelayCleanupScope {
    case transport
    case persistentSlot
}
