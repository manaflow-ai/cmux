import Foundation

/// The two transport ciphers after `Split()`, oriented for one side.
struct NoiseTransportCiphers: Sendable {
    var send: NoiseCipherState
    var receive: NoiseCipherState
    /// The handshake hash `h`, a channel binding.
    let handshakeHash: Data
}
