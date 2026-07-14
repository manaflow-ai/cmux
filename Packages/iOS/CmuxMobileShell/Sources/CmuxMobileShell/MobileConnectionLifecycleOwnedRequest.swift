/// One awaitable request admitted to the connection lifecycle owner.
struct MobileConnectionLifecycleOwnedRequest: Equatable {
    var id: UInt64
    var effect: MobileConnectionLifecycleEffect?
}
