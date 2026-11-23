import CmuxNextDictation
import Foundation
import Network
import Synchronization

/// One dictation session's live stream through the LOCAL acpmux (`_acpmux/voice/stream.*`, acpmux
/// `server/voice_stream.rs`), on a unix connection of its own: acpmux holds the provider's
/// WebSocket, reads the key from the Keychain itself and runs the session reducer (crate
/// cmux-voice), so this file only carries audio up and the reduced words down. The stream ends
/// with this connection.
///
/// Audio chunks go in order on one writer task, each numbered (`seq`); acpmux puts them back in
/// order if its requests run at once. Its `stream.event` notifications become ``events``.
nonisolated final class AcpmuxDictationStream: DictationLiveStream {
    /// What the writer sends, in order.
    private enum Outgoing: Sendable {
        case audio([Int16])
        case stop(CheckedContinuation<Void, any Error>)
    }

    /// acpmux's own stop waits up to 20 s (`STOP_WAIT`) for the last words.
    static let stopDeadline: Duration = .seconds(25)
    static let startDeadline: Duration = .seconds(15)
    static let eventMethod = "_acpmux/voice/stream.event"

    let events: AsyncStream<DictationTranscriptionEvent>
    private let shown: AsyncStream<DictationTranscriptionEvent>.Continuation
    private let connection: NWConnection
    private let stream: String
    private let outgoing: AsyncStream<Outgoing>.Continuation
    /// The stops waiting on acpmux's answer, by request id.
    private let replies = Mutex<[Int: CheckedContinuation<Void, any Error>]>([:])
    private let tasks = Mutex<[Task<Void, Never>]>([])

    private init(connection: NWConnection, stream: String) {
        self.connection = connection
        self.stream = stream
        (events, shown) = AsyncStream.makeStream(of: DictationTranscriptionEvent.self)
        let (items, outgoing) = AsyncStream.makeStream(of: Outgoing.self)
        self.outgoing = outgoing
        // task-owner: stored in tasks; both end with the connection, which cancel() and stop() close
        let writer = Task { [self] in await write(items) }
        let reader = Task { [self] in await read() }
        tasks.withLock { $0 = [writer, reader] }
    }

    /// A stream for a session in `locale`, nil when the person's provider does not stream.
    /// Throws ``DictationFailure/providerFailed(code:detail:)`` for acpmux's refusal (no key, not
    /// configured), or the socket's failure.
    static func open(socketPath: String, locale: Locale) async throws -> AcpmuxDictationStream? {
        let connection = NWConnection(to: try AcpmuxStatusClient.unixEndpoint(socketPath), using: .tcp)
        let params: [String: any Sendable] = ["language": locale.identifier(.bcp47)]
        let result: [String: Any]
        do {
            result = try await withAgentPaneDeadline(startDeadline, label: "acpmux voice stream.start",
                                                     onTimeout: { connection.cancel() }) {
                ResultBox(try await AcpmuxStatusClient.exchange("_acpmux/voice/stream.start", params: params,
                                                                transport: AcpmuxSocketTransport(connection: connection),
                                                                detailed: true))
            }.value
        } catch {
            connection.cancel()
            throw error
        }
        if let id = result["stream"] as? String, !id.isEmpty {
            return AcpmuxDictationStream(connection: connection, stream: id)
        }
        connection.cancel()
        if let failure = result["error"] as? [String: Any] { throw Self.failure(failure) }
        return nil
    }

    func send(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        outgoing.yield(.audio(samples))
    }

    func stop() async throws {
        let connection = connection
        defer { close() }
        try await withAgentPaneDeadline(Self.stopDeadline, label: "acpmux voice stream.stop",
                                        onTimeout: { connection.cancel() }) { [outgoing] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if case .terminated = outgoing.yield(.stop(continuation)) {
                    continuation.resume(throwing: DictationFailure.providerFailed(code: "offline", detail: ""))
                }
            }
        }
    }

    func cancel() async {
        // The connection's end cancels the stream in acpmux (`Streams::close_all`).
        close()
    }

    private func close() {
        outgoing.finish()
        shown.finish()
        connection.cancel()
        failWaiting(code: "offline")
    }

    private func failWaiting(code: String) {
        let waiting = replies.withLock { replies in
            defer { replies = [:] }
            return Array(replies.values)
        }
        for continuation in waiting {
            continuation.resume(throwing: DictationFailure.providerFailed(code: code, detail: ""))
        }
    }

    // MARK: - The writer and the reader

    private func write(_ items: AsyncStream<Outgoing>) async {
        var seq = 0
        var id = 10
        for await item in items {
            var params: [String: Any] = ["stream": stream, "seq": seq]
            let method: String
            switch item {
            case .audio(let samples):
                method = "_acpmux/voice/stream.audio"
                params["pcm"] = samples.withUnsafeBytes { Data($0) }.base64EncodedString()
            case .stop(let continuation):
                method = "_acpmux/voice/stream.stop"
                replies.withLock { $0[id] = continuation }
            }
            seq += 1
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            id += 1
            guard let line = try? JSONSerialization.data(withJSONObject: request) + Data([0x0A]) else { continue }
            do {
                try await AcpmuxStatusClient.send(line, on: connection)
            } catch {
                close()
                return
            }
        }
    }

    private func read() async {
        var buffer = Data()
        // wakeup-allow: each pass awaits socket data; EOF, an error or close() ends it
        while let chunk = try? await AcpmuxStatusClient.receive(on: connection) {
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    handle(object)
                }
            }
            // A line over 1 MiB is no line acpmux sends here.
            if buffer.count > 1 << 20 { break }
        }
        close()
    }

    private func handle(_ object: [String: Any]) {
        if object["method"] as? String == Self.eventMethod {
            guard let params = object["params"] as? [String: Any], params["stream"] as? String == stream else { return }
            if let text = params["partial"] as? String {
                shown.yield(.partial(text))
            } else if let text = params["final"] as? String {
                shown.yield(.final(text))
            } else if params["end"] != nil {
                shown.finish()
            }
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue,
              let continuation = replies.withLock({ $0.removeValue(forKey: id) }) else { return }
        if object["error"] != nil {
            continuation.resume(throwing: DictationFailure.providerFailed(code: "provider_error", detail: ""))
        } else if let failure = (object["result"] as? [String: Any])?["error"] as? [String: Any] {
            continuation.resume(throwing: Self.failure(failure))
        } else {
            continuation.resume()
        }
    }

    private static func failure(_ error: [String: Any]) -> DictationFailure {
        .providerFailed(code: error["code"] as? String ?? "bad_response", detail: error["detail"] as? String ?? "")
    }
}
