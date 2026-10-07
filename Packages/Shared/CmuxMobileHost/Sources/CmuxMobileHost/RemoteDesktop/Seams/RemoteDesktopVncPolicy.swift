public import CmuxRemoteDesktop

/// Which VNC servers a phone may ask this Mac to dial.
public enum RemoteDesktopVncPolicy: Hashable, Sendable {
    case off
    /// Any hostname or IP; `allowLoopback` covers this Mac's own services
    /// (a local VM or simulator VNC port).
    case allowed(allowLoopback: Bool)

    public func permits(_ address: VncAddress) -> Bool {
        switch self {
        case .off: false
        case .allowed(let loopback): loopback || !address.isLoopback
        }
    }
}
