/// Why the host dropped an incoming connection before it became a transport.
public enum DirectAcceptError: Error, Sendable, Hashable {
    case unauthorized(DirectPublicKey)
    case handshakeTimedOut
    case listenerFailed(String)
}
