/// Allows a fixed set of device keys (tests, and a host with a static list).
public struct DirectPinnedAuthorizer: DirectAuthorizer {
    public var allowed: Set<DirectPublicKey>

    public init(allowed: Set<DirectPublicKey>) {
        self.allowed = allowed
    }

    public func authorize(device: DirectPublicKey) async -> Bool {
        allowed.contains(device)
    }
}
