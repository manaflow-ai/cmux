import Foundation

/// Streams MiniMax speech as mono 32 kHz signed 16-bit little-endian PCM.
///
/// Each invocation owns its requests. Cancelling the calling task stops its
/// network transfer; a sink failure stops that request without retrying.
///
/// ```swift
/// let client = MiniMaxSpeechClient(session: URLSession(configuration: .ephemeral))
/// try await client.synthesize(
///     text: selection, configuration: configuration, apiKey: key, audioSink: consumePCM
/// )
/// ```
public actor MiniMaxSpeechClient: ReadAloudSynthesizing {
    private let session: URLSession

    /// Creates a client using an injected session without assuming ownership of it.
    ///
    /// - Parameter session: A session configured for ephemeral storage, with no
    ///   persistent URL cache or credential storage. The client never invalidates it.
    public init(session: URLSession) {
        self.session = session
    }

    /// Reads the full selection through sequential, bounded provider requests.
    ///
    /// Empty or whitespace-only selections return without making a request.
    /// Paragraph and sentence boundaries are preferred when splitting long text;
    /// no text is silently truncated. The sink receives complete PCM samples and
    /// is awaited before reading more network bytes. It must cooperate with task
    /// cancellation; network cancellation does not depend on sink cooperation.
    /// - Parameters:
    ///   - text: Selected text to transmit to MiniMax.
    ///   - configuration: A supported MiniMax model, nonempty voice ID, and speed in 0.5...2.
    ///   - apiKey: A nonempty ASCII bearer credential without whitespace or controls.
    ///   - audioSink: A backpressured consumer, called sequentially with PCM data.
    /// - Throws: Cancellation, safe localized transport errors, or the sink's error.
    public func synthesize(
        text: String,
        configuration: ReadAloudConfiguration,
        apiKey: String,
        audioSink: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard text.contains(where: { !$0.isWhitespace }) else { return }
        try configuration.validate()
        guard !apiKey.isEmpty, apiKey.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw ReadAloudTransportError.invalidCredential }
        var chunks = ReadAloudTextChunks(text: text)
        while let chunk = try chunks.next() {
            // Whitespace remains in the lossless partition, but cannot produce speech alone.
            guard chunk.contains(where: { !$0.isWhitespace }) else { continue }
            let request = try request(text: chunk, configuration: configuration, apiKey: apiKey)
            try await stream(request: request, audioSink: audioSink)
        }
    }

    private func stream(
        request: URLRequest,
        audioSink: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            // Foundation's async API propagates cancellation while awaiting headers,
            // before the underlying task is available through AsyncBytes.
            (bytes, response) = try await session.bytes(for: request, delegate: ReadAloudRequestDelegate())
        } catch {
            throw transportError(error)
        }
        let networkTask = bytes.task
        defer { networkTask.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw ReadAloudTransportError.invalidResponse
            }
            guard http.statusCode == 200 else {
                throw ReadAloudTransportError.http(status: http.statusCode)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var iterator = bytes.makeAsyncIterator()
            guard contentType == "text/event-stream" else {
                // MiniMax can return a JSON error with HTTP 200. Bound that error
                // document; never buffer a successful audio response as a fallback.
                guard contentType == "application/json" else {
                    throw ReadAloudTransportError.invalidResponse
                }
                var document = Data()
                while let byte = try await nextByte(&iterator) {
                    guard document.count < 64 * 1_024 else {
                        throw ReadAloudTransportError.responseTooLarge
                    }
                    document.append(byte)
                }
                var parser = MiniMaxAudioParser()
                _ = try parser.consume(document)
                throw ReadAloudTransportError.invalidResponse
            }
            var frames = ReadAloudSSEParser()
            var audio = MiniMaxAudioParser()
            while let byte = try await nextByte(&iterator) {
                if let event = try frames.consume(byte) {
                    if let pcm = try audio.consume(event) {
                        try Task.checkCancellation()
                        try await audioSink(pcm)
                        try Task.checkCancellation()
                    }
                    if audio.isComplete {
                        try audio.finish()
                        return
                    }
                }
            }
            try frames.finish()
            try audio.finish()
        } onCancel: {
            networkTask.cancel()
        }
    }

    private func nextByte(_ iterator: inout URLSession.AsyncBytes.Iterator) async throws -> UInt8? {
        try Task.checkCancellation()
        do {
            return try await iterator.next()
        } catch {
            throw transportError(error)
        }
    }

    private func transportError(_ error: any Error) -> any Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        return ReadAloudTransportError.network
    }


    private func request(text: String, configuration: ReadAloudConfiguration, apiKey: String) throws -> URLRequest {
        guard let endpoint = URL(string: "https://api.minimax.io/v1/t2a_v2") else {
            throw ReadAloudTransportError.invalidResponse
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": configuration.model,
                "text": text,
                "stream": true,
                "stream_options": ["exclude_aggregated_audio": true],
                "output_format": "hex",
                "voice_setting": ["voice_id": configuration.voiceID, "speed": configuration.speed, "vol": 1, "pitch": 0],
                "audio_setting": ["format": "pcm", "sample_rate": 32_000, "channel": 1],
            ])
        } catch {
            throw ReadAloudTransportError.invalidConfiguration
        }
        return request
    }
}
