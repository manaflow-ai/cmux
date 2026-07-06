public import Darwin

public struct SocketClientAuthorization {
    public init() {}

    public func isCmuxOnlyClientAllowed(
        peerProcessID: pid_t?,
        peerHasSameUID _: Bool,
        isDescendant: (pid_t) -> Bool
    ) -> Bool {
        if let peerProcessID {
            return isDescendant(peerProcessID)
        }
        return false
    }
}
