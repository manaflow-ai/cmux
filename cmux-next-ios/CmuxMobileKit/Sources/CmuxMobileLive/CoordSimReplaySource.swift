// DEBUG builds only: the list rig's heavy coordinator chat (verify/listperf, case coord-sim).
#if DEBUG
import CmuxMobileAgentChat
import Foundation
import OSLog

/// A chat replayed from a file of acpmux records (`{sessionId, seq, at, dir, kind, msg}`, one a line), as
/// coord-sim writes them (`coord-sim surface --target ios`: one coordinator shaped like the heaviest real ones,
/// filler text). The first `history` records are the chat before the reader came: the newest of them that fit
/// `pageBytes` arrive as one batch, as an attach page does (`AcpmuxSessionSource`, 128 KB open budget); the rest
/// stream at the pace their `at` says. Each record goes through `AcpmuxRecords`, the live chat's own mapping.
/// It logs `FRAMELOG list-stress coord-sim attach ms=… records=… bytes=…` (the read, parse and map of the page to
/// its batch handed to the chat) and, at the end, `coord-sim streamed records=… behind_max_ms=…`.
@MainActor
public final class CoordSimReplaySource: AgentSessionSource {
    public let summary: AgentSessionSummary
    private let url: URL
    private let history: Int
    private let pageBytes: Int
    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")

    public init(summary: AgentSessionSummary, url: URL, history: Int, pageBytes: Int = 128 * 1024) {
        self.summary = summary
        self.url = url
        self.history = history
        self.pageBytes = pageBytes
    }

    isolated deinit {
        task?.cancel()
        for continuation in continuations { continuation.finish() }
    }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        continuations.append(continuation)
        guard task == nil else { return stream }
        let (url, history, pageBytes, sessionID) = (url, history, pageBytes, summary.id)
        task = Task { [weak self] in
            let began = ContinuousClock.now
            // Read and decode off the main actor: the file is megabytes.
            let lines = await Task.detached(priority: .userInitiated) { () -> [(Data, JSONValue)] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                let decoder = JSONDecoder()
                return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
                    let bytes = Data(line)
                    return (try? decoder.decode(JSONValue.self, from: bytes)).map { (bytes, $0) }
                }
            }.value
            guard let self else { return }
            let records = AcpmuxRecords(sessionID: sessionID)
            let past = lines.prefix(history)
            var page: [JSONValue] = []
            var bytes = 0
            for (data, value) in past.reversed() {
                if bytes + data.count > pageBytes, !page.isEmpty { break }
                bytes += data.count
                page.append(value)
            }
            let batch = page.reversed().flatMap { records.map($0) }
            self.emit(.batch(batch))
            await Task.yield()
            let ms = (ContinuousClock.now - began).milliseconds
            self.log.notice("FRAMELOG list-stress coord-sim attach ms=\(ms, privacy: .public) records=\(page.count, privacy: .public) bytes=\(bytes, privacy: .public) events=\(batch.count, privacy: .public)")
            // The live records, paced by their `at` from the last history record's.
            let start = ContinuousClock.now
            let base = past.last?.1["at"]?.numberValue ?? lines.first?.1["at"]?.numberValue ?? 0
            var behind = 0.0
            var streamed = 0
            for (_, value) in lines.dropFirst(history) {
                if Task.isCancelled { return }
                let due = ((value["at"]?.numberValue ?? base) - base) / 1000
                let now = Double((ContinuousClock.now - start).milliseconds) / 1000
                if due > now {
                    try? await Task.sleep(for: .milliseconds(Int((due - now) * 1000)))
                } else {
                    behind = max(behind, (now - due) * 1000)
                }
                for event in records.map(value) { self.emit(event) }
                streamed += 1
            }
            self.log.notice("FRAMELOG list-stress coord-sim streamed records=\(streamed, privacy: .public) behind_max_ms=\(Int(behind), privacy: .public)")
        }
        return stream
    }

    private func emit(_ event: AgentSessionEvent) {
        for continuation in continuations { continuation.yield(event) }
    }

    /// A replay takes no prompts: they go back to the composer.
    public func send(_ intent: AgentClientIntent) {
        if case .prompt(let text, let attachments, _, let promptID, _) = intent {
            emit(.promptNotSent(text: text, attachments: attachments, promptID: promptID, reason: "Replay. Not sent."))
        }
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
#endif
