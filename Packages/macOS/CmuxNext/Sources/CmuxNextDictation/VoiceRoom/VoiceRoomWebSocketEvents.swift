public import Foundation

/// ``VoiceRoomEventSource`` from the room's WebSocket, joined as an observer, so this Mac's
/// capture is not a person in the room.
public struct VoiceRoomWebSocketEvents: VoiceRoomEventSource {
    private let address: VoiceRoomAddress
    private let session: URLSession

    /// - Parameters:
    ///   - address: The room.
    ///   - session: The URL session.
    public init(address: VoiceRoomAddress, session: URLSession = .shared) {
        self.address = address
        self.session = session
    }

    public func pauses() -> AsyncStream<Bool> {
        let url = address.events
        let session = session
        // Only the newest pause state matters.
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let socket = session.webSocketTask(with: url)
        let reader = Task {
            socket.resume()
            // Each receive awaits the next message; a close, an error or cancel (which cancels the socket) ends it.
            while let message = try? await socket.receive() {
                if let paused = Self.paused(in: message) { continuation.yield(paused) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            reader.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
        return stream
    }

    /// The pause state a room message carries (`welcome`, `state`, `paused`), else nil.
    static func paused(in message: URLSessionWebSocketTask.Message) -> Bool? {
        let data: Data? = switch message {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: nil
        }
        guard let data, let event = try? JSONDecoder().decode(Event.self, from: data) else { return nil }
        guard ["welcome", "state", "paused"].contains(event.t) else { return nil }
        return event.paused
    }

    private struct Event: Decodable {
        let t: String
        let paused: Bool?
    }
}
