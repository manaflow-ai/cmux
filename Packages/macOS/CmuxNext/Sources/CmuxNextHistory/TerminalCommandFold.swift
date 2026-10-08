public import Foundation

/// One `shell.command.finished` session journal record
/// (`terminal-command-journal-v1`, cmux-tui/spec/commands.md).
public nonisolated struct CommandJournalRecord: Hashable, Sendable, Decodable {
    public struct Payload: Hashable, Sendable, Decodable {
        public var command: String?
        public var cwd: String?
        public var exitCode: Int?
        public var startedAtMs: String?
        public var durationMs: String?

        enum CodingKeys: String, CodingKey {
            case command, cwd
            case exitCode = "exit_code"
            case startedAtMs = "started_at_ms"
            case durationMs = "duration_ms"
        }
    }

    public var sequence: UInt64
    public var kind: String
    public var subjects: [AgentJournalRecord.Subject]
    public var payload: Payload?

    enum CodingKeys: String, CodingKey { case sequence, kind, subjects, payload }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .sequence), let value = UInt64(text) {
            sequence = value
        } else {
            sequence = try c.decode(UInt64.self, forKey: .sequence)
        }
        kind = try c.decode(String.self, forKey: .kind)
        subjects = try c.decodeIfPresent([AgentJournalRecord.Subject].self, forKey: .subjects) ?? []
        payload = try c.decodeIfPresent(Payload.self, forKey: .payload)
    }
}

/// One machine's finished commands from its journal, newest last, at most
/// `capacity`; re-reading from an older cursor never double counts.
public nonisolated struct TerminalCommandFold: Hashable, Sendable {
    public static let journalKind = "shell.command.finished"
    public let machine: String
    public let capacity: Int
    public private(set) var cursor: UInt64 = 0
    public private(set) var commands: [TerminalCommand] = []

    public init(machine: String, capacity: Int = 1_000) {
        self.machine = machine
        self.capacity = max(1, capacity)
    }

    public mutating func apply(_ records: [CommandJournalRecord]) {
        for record in records where record.sequence > cursor {
            cursor = record.sequence
            guard record.kind == Self.journalKind, let payload = record.payload,
                  let started = payload.startedAtMs.flatMap(Int64.init),
                  let terminal = record.subjects.first(where: { $0.kind == "terminal" })?.id else { continue }
            commands.append(TerminalCommand(
                machine: machine, terminal: terminal, command: payload.command, cwd: payload.cwd, exitCode: payload.exitCode,
                startedAt: Date(timeIntervalSince1970: TimeInterval(started) / 1000),
                duration: payload.durationMs.flatMap(Double.init).map { $0 / 1000 }))
        }
        if commands.count > capacity { commands.removeFirst(commands.count - capacity) }
    }
}

extension TerminalCommand {
    /// `<machine>/<terminal>/<start ms>`.
    public nonisolated var qualifiedID: String {
        "\(machine)/\(terminal)/\(Int64((startedAt.timeIntervalSince1970 * 1000).rounded()))"
    }
}
