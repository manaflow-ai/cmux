/// One live local bridge server and the logical generation it serves.
struct RemotePTYBridgeServerRecord {
    let server: RemotePTYBridgeServer
    let lifecycleKey: RemotePTYLifecycleKey
    let onLifecycleEnded: @Sendable () -> Void
}
