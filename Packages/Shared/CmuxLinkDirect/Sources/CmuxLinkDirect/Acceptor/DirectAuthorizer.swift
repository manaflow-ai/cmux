/// Decides whether a device key may open a session (the host's paired-device
/// trust store, lane B6; plugged in by B5).
public protocol DirectAuthorizer: Sendable {
    func authorize(device: DirectPublicKey) async -> Bool
}
