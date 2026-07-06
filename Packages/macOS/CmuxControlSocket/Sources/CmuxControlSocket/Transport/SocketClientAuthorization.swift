public import Darwin

public enum SocketClientAuthorization {
    public static func isCmuxOnlyClientAllowed(
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        isDescendant: (pid_t) -> Bool
    ) -> Bool {
        if let peerProcessID {
            return isDescendant(peerProcessID)
        }
        return peerHasSameUID
    }
}
