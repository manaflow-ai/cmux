public import Foundation

/// ``VoiceRoomPosting`` over HTTP: `POST <room>/api/transcript` with the line as JSON.
public struct VoiceRoomHTTPPoster: VoiceRoomPosting {
    private let address: VoiceRoomAddress
    private let session: URLSession

    /// - Parameters:
    ///   - address: The room.
    ///   - session: The URL session; tests pass one with a stub protocol.
    public init(address: VoiceRoomAddress, session: URLSession = .shared) {
        self.address = address
        self.session = session
    }

    public func post(_ line: VoiceRoomLine) async throws -> Bool {
        var request = URLRequest(url: address.transcript, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(Body(text: line.text, level: line.level, kind: line.kind.rawValue))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceRoomError.status(status) }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw VoiceRoomError.badReply }
        return reply.paused
    }

    private struct Body: Encodable {
        let text: String
        let level: Float
        let kind: String
    }

    private struct Reply: Decodable {
        let paused: Bool
    }
}
