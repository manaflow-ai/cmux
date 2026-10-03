public import Foundation

/// Where the chief experiment lives (plans/cmux-next/chief.md, branch
/// feat-cmux-next-chief only). Read from `~/.config/cmux/chief-experiment.json`:
/// `{"url": "https://…workers.dev", "token": "…", "chief": "lawrence", "me": "Lawrence"}`.
public nonisolated struct ChiefExperimentConfig: Hashable, Sendable, Codable {
    public var url: URL
    public var token: String
    /// The chief's id on the Worker (one chief, one memory).
    public var chief: String
    /// The name the chief sees for the person.
    public var me: String

    public init(url: URL, token: String, chief: String, me: String) {
        self.url = url
        self.token = token
        self.chief = chief
        self.me = me
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/cmux/chief-experiment.json")
    }

    /// Nil when the file is missing or unreadable: the experiment stays hidden.
    public static func load(from file: URL = defaultFile) -> ChiefExperimentConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ChiefExperimentConfig.self, from: data)
    }
}

/// One message as the Worker returns it (`/v1/chiefs/:id/messages`).
public nonisolated struct ChiefWireMessage: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case human, chief, worker, error
    }

    public var seq: UInt64
    public var id: String
    public var kind: Kind
    public var author: String
    public var text: String
    /// Milliseconds since 1970.
    public var at: Double

    public init(seq: UInt64, id: String, kind: Kind, author: String, text: String, at: Double) {
        self.seq = seq
        self.id = id
        self.kind = kind
        self.author = author
        self.text = text
        self.at = at
    }

    /// The client id a person's message was sent with (`human:<id>` on the Worker).
    public var clientMessageID: String? {
        kind == .human && id.hasPrefix("human:") ? String(id.dropFirst("human:".count)) : nil
    }
}

/// Why a Worker call failed, in the terms the Home store acts on.
public nonisolated enum ChiefTransportError: Error, Hashable, Sendable {
    /// No answer (network down, timeout): the call may or may not have happened.
    case unreachable
    case unauthorized
    case invalid(String)
    /// The Worker failed after accepting the call.
    case server(Int)
}

/// The Worker's chief routes. A protocol so tests replace the network.
public nonisolated protocol ChiefTransport: Sendable {
    /// Batches of messages: everything after `after` first, then each new
    /// message as the Worker records it. Ends (or throws) when the socket closes.
    func stream(after: UInt64) -> AsyncThrowingStream<[ChiefWireMessage], any Error>
    /// The newest `tail` messages, ascending.
    func tail(_ count: Int) async throws -> [ChiefWireMessage]
    /// Up to `limit` messages before `before`, ascending.
    func page(before: UInt64, limit: Int) async throws -> [ChiefWireMessage]
    /// Sends a person's message; idempotent by `clientID`.
    func send(clientID: String, text: String, from: String) async throws -> ChiefWireMessage
}

/// `ChiefTransport` over HTTPS with the experiment's bearer token.
public nonisolated struct ChiefHTTPTransport: ChiefTransport {
    let config: ChiefExperimentConfig
    let session: URLSession

    public init(config: ChiefExperimentConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private struct Page: Decodable { var messages: [ChiefWireMessage] }

    private var base: URL {
        config.url.appending(path: "v1/chiefs").appending(path: config.chief).appending(path: "messages")
    }

    public func stream(after: UInt64) -> AsyncThrowingStream<[ChiefWireMessage], any Error> {
        var components = URLComponents(url: config.url.appending(path: "v1/chiefs").appending(path: config.chief).appending(path: "stream"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "after", value: String(after))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "authorization")
        let task = session.webSocketTask(with: request)
        let (stream, continuation) = AsyncThrowingStream<[ChiefWireMessage], any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
        // task-owner: the stream (cancelled by onTermination); event-driven (socket receive)
        let reader = Task {
            task.resume()
            do {
                // wakeup-allow: blocks on receive() until a frame arrives; a closed or failed socket throws and ends the loop
                while !Task.isCancelled {
                    let frame = try await task.receive()
                    let data: Data
                    switch frame {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: continue
                    }
                    continuation.yield(try JSONDecoder().decode(Page.self, from: data).messages)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: ChiefTransportError.unreachable)
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }
        return stream
    }

    public func tail(_ count: Int) async throws -> [ChiefWireMessage] {
        try await get([URLQueryItem(name: "tail", value: String(count))], timeout: 30)
    }

    public func page(before: UInt64, limit: Int) async throws -> [ChiefWireMessage] {
        try await get([URLQueryItem(name: "before", value: String(before)), URLQueryItem(name: "limit", value: String(limit))],
                      timeout: 30)
    }

    public func send(clientID: String, text: String, from: String) async throws -> ChiefWireMessage {
        var request = URLRequest(url: base, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_msg_id": clientID, "text": text, "from": from])
        return try JSONDecoder().decode(ChiefWireMessage.self, from: try await load(request))
    }

    private func get(_ query: [URLQueryItem], timeout: TimeInterval) async throws -> [ChiefWireMessage] {
        let request = URLRequest(url: base.appending(queryItems: query), timeoutInterval: timeout)
        return try JSONDecoder().decode(Page.self, from: try await load(request)).messages
    }

    private func load(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChiefTransportError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw ChiefTransportError.unauthorized
        case 400..<500: throw ChiefTransportError.invalid(String(decoding: data, as: UTF8.self))
        default: throw ChiefTransportError.server(status)
        }
    }
}
