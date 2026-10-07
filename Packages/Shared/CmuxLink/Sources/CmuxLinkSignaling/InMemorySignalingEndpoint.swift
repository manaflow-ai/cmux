/// One install's channel on an `InMemorySignalingHub`.
struct InMemorySignalingEndpoint: SignalingChannel {
    let id: String
    let hub: InMemorySignalingHub
    let incoming: AsyncStream<SignalMessage>

    func send(_ message: SignalMessage) async throws {
        try hub.relay(message, from: id)
    }
}
