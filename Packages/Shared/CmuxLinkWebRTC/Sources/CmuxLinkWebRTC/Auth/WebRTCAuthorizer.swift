/// Decides whether a device key may open a session with this host (the
/// paired-device trust store, B6; plugged in by B5). `install` is the
/// relay-authenticated sender, when the relay supplied one.
public protocol WebRTCAuthorizer: Sendable {
    func authorize(device: WebRTCPublicKey, install: String?) async -> Bool
}
