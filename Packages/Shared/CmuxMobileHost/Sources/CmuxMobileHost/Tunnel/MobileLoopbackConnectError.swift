/// Why a loopback connect failed.
public enum MobileLoopbackConnectError: Error, Hashable, Sendable {
    case refused
    case timedOut
    case failed
}
