public import CmuxMobileWire

/// The session lifecycle the UI shows (connected, reconnecting, failed).
public enum ControlPlaneState: Hashable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected(HelloOKFrame)
    case disconnected(attempt: Int)
    case failed(ControlPlaneError)
    case stopped
}
