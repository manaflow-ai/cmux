import CmuxHomeCore
import Foundation

/// One line of a conversation's JSON Lines file.
enum ChiefLogRecord: Codable, Sendable {
    /// The summary after a change (last one wins).
    case summary(ConversationSummary)
    /// A message after a commit or an update (last one per id wins).
    case message(Message)
    /// The brain's CLI session to resume (last one wins).
    case session(String?)
}

/// A conversation's file, `conversations/<id>.jsonl`: an append-only log of
/// ``ChiefLogRecord`` lines, compacted to a snapshot on load.
///
/// Crash safety: each change appends whole lines; a crash mid-write leaves at
/// most one partial last line, which loading skips. Loading then rewrites the
/// file as a compacted snapshot (temp file plus atomic replace), so later
/// appends never join a partial line.
final class ChiefConversationLog {
    let url: URL
    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    /// Reads the file. Nil when it has no summary record.
    static func load(_ url: URL) throws -> ChiefConversationState? {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var summary: ConversationSummary?
        var messages: [MessageID: Message] = [:]
        var session: String?
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // A partial last line (a crash mid-write) does not decode: skip it.
            guard let record = try? decoder.decode(ChiefLogRecord.self, from: Data(line)) else { continue }
            switch record {
            case .summary(let value): summary = value
            case .message(let value): messages[value.id] = value
            case .session(let value): session = value
            }
        }
        guard var summary else { return nil }
        // The messages decide the tail; a summary written before its message record lost is behind.
        summary.lastSeq = 0
        summary.lastMessage = nil
        var state = ChiefConversationState(summary: summary, messages: Array(messages.values), cliSession: session)
        state.summary.rev = max(state.summary.rev, state.summary.lastSeq)
        return state
    }

    /// Replaces the file with a snapshot of `state`.
    func rewrite(_ state: ChiefConversationState) throws {
        try? handle?.close()
        handle = nil
        var data = Data()
        var records: [ChiefLogRecord] = [.summary(state.summary), .session(state.cliSession)]
        records += state.messages.map(ChiefLogRecord.message)
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Appends records as whole lines.
    func append(_ records: [ChiefLogRecord]) throws {
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
        }
        guard let handle else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
