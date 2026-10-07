/// How one direction of a forwarded stream ended.
enum TcpForwardEnd: Sendable {
    /// The Mac socket finished sending (sent to the phone as `fin`).
    case socketFinished
    /// The phone sent `fin`; the socket's write side is shut.
    case phoneFinished
    case socketFailed
    /// The phone closed the channel or the link channel ended.
    case phoneClosed
    case revoked
}
