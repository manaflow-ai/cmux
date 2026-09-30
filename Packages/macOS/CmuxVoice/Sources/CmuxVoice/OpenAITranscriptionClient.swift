public import Foundation

/// Sends one recorded clip to OpenAI's `/v1/audio/transcriptions` endpoint.
///
/// Used by ``CloudDictationTranscriber`` with the user's own API key. The
/// transport is injected so tests can check the request and feed canned
/// responses without a network.
public struct OpenAITranscriptionClient: Sendable {
    /// Performs one HTTP request.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Default model: OpenAI's recommended model for recorded speech.
    public static let defaultModel = "gpt-transcribe"

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// Context for the model: dictation lands in a terminal or an agent
    /// prompt, so code terms should come through verbatim.
    static let prompt = "Dictation into a developer's terminal or coding agent prompt. Keep code identifiers, file names, commands and technical terms verbatim."

    private let apiKey: String
    private let model: String
    private let transport: Transport

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - apiKey: The user's OpenAI API key.
    ///   - model: Transcription model identifier.
    ///   - transport: HTTP transport; defaults to `URLSession.shared`.
    public init(
        apiKey: String,
        model: String = OpenAITranscriptionClient.defaultModel,
        transport: @escaping Transport = { request in try await URLSession.shared.data(for: request) }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    /// Transcribes a WAV clip.
    ///
    /// - Returns: The transcript, trimmed.
    /// - Throws: ``DictationFailure/cloudTranscriptionFailed(_:)`` for HTTP,
    ///   auth and decoding errors.
    public func transcribe(wav: Data) async throws -> String {
        let request = makeRequest(wav: wav, boundary: "cmux-\(UUID().uuidString)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DictationFailure.cloudTranscriptionFailed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DictationFailure.cloudTranscriptionFailed(Self.errorMessage(status: status, body: data))
        }
        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw DictationFailure.cloudTranscriptionFailed("unreadable response")
        }
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func makeRequest(wav: Data, boundary: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // Long clips can take minutes to process; the controller's stop
        // deadline bounds the whole wait.
        request.timeoutInterval = 600
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("prompt", Self.prompt)
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func errorMessage(status: Int, body: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: body) {
            return "HTTP \(status): \(decoded.error.message)"
        }
        return "HTTP \(status)"
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }

        let error: Detail
    }
}
