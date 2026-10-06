import CmuxNextDaemon
import Darwin
import Foundation
import SQLite3

/// What the Chief owner does for the migration: the Chief conversation and
/// the `conversation-import` command.
protocol ChiefMigrationOwner: Sendable {
    func chiefConversation() async throws -> String
    func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult
}

/// The once-per-Chief-home move of the old per-tag Chiefs
/// (home-state-ownership.md section 7), run by the app when the Chief owner
/// first answers and before Home or the brain host use it. The owner imports
/// the conversation history (it keeps seq authority); the memory is written
/// while the app holds the Chief home's host lock, so no host writes it at
/// the same time. Old homes and stores are only read. A tag whose old host
/// still runs blocks the move until a later launch; nothing is stopped.
nonisolated enum ChiefMigration {
    enum Outcome: Sendable, Equatable {
        case done(messages: Int, memoryEntries: Int)
        /// Nothing to move, or already moved, or an isolated home.
        case nothingToDo
        /// Old hosts still run (their tags); retried at the next launch.
        case blocked([String])
        /// The owner refused the history (it already holds newer messages).
        case refused(String)
    }

    struct Old: Sendable, Equatable {
        var tag: String
        var muxHome: URL
        var store: URL
    }

    static let recordName = "migration.json"

    /// Every old per-tag Chief on this Mac: `~/.cmux/mux/tags/<tag>` and the
    /// tag daemon's conversation store.
    static func oldChiefs(userHome: URL, applicationSupport: URL) -> [Old] {
        let tags = userHome.appendingPathComponent(".cmux/mux/tags", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tags.path)) ?? []
        return names.sorted().map { tag in
            let session = "cmux-app-\(tag)"
            let store = applicationSupport.appendingPathComponent("cmux/tags/\(tag)/tui/\(sessionComponent(session))/conversations.sqlite3")
            return Old(tag: tag, muxHome: tags.appendingPathComponent(tag, isDirectory: true), store: store)
        }
    }

    /// cmux-tui `session_storage_component`: readable prefix plus FNV-1a 64.
    static func sessionComponent(_ session: String) -> String {
        var readable = ""
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in session.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
            if readable.utf8.count < 48 {
                let scalar = Character(UnicodeScalar(byte))
                readable.append(scalar.isASCII && (scalar.isLetter || scalar.isNumber || scalar == "-" || scalar == "_") ? scalar : "_")
            }
        }
        return (readable.isEmpty ? "session" : readable) + "-" + String(format: "%016llx", hash)
    }

    /// Runs the move for `home`. Idempotent: a finished move is recorded in
    /// `<home>/migration.json`, and the owner skips what it already holds.
    static func run(home: ChiefHome, owner: some ChiefMigrationOwner, olds: [Old], tool: (any ChiefMemoryTool)? = nil) async throws -> Outcome {
        let record = home.root.appendingPathComponent(recordName)
        if home.isolated || FileManager.default.fileExists(atPath: record.path) { return .nothingToDo }
        let blocking = olds.filter { lockHeld(at: $0.muxHome.appendingPathComponent("state/host.lock")) }.map(\.tag)
        if !blocking.isEmpty { return .blocked(blocking) }
        let lockPath = home.root.appendingPathComponent("state/host.lock")
        try FileManager.default.createDirectory(at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let lock = HostLock(path: lockPath) else { return .blocked([home.root.lastPathComponent]) }
        defer { lock.release() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chief-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sources = olds.compactMap { readSource($0, tool: tool, scratch: scratch) }
        let plan = ChiefMigrationPlan.make(sources)
        var outcome = Outcome.nothingToDo
        if !plan.items.isEmpty {
            let conversation = try await owner.chiefConversation()
            let result: ConversationImportResult
            do {
                result = try await owner.importHistory(ConversationImportRequest(conversation: conversation, messages: plan.imports))
            } catch DaemonError.command(_, let message, _, _, _) where message.contains("import_out_of_order") {
                try writeRecord(record, olds: olds, status: "refused: \(message)")
                return .refused(message)
            }
            let entries = try writeMemory(home: home, plan: plan, sources: sources, conversation: conversation,
                                          loggedSeq: result.conversation.lastSeq, tool: tool, scratch: scratch)
            outcome = .done(messages: plan.items.count, memoryEntries: entries)
        }
        try writeRecord(record, olds: olds, status: "done")
        return outcome
    }

    // MARK: Memory

    /// Writes the merged OptChat memory and host state when the Chief home
    /// has no memory yet; returns the number of log entries. The memory goes
    /// through the store's own import (`memory import`) from JSONL day files
    /// staged here; a build without the tool leaves the day files where the
    /// host imports them at its first start. `host.json` binds the host to
    /// the Chief conversation with every imported message logged (the store
    /// takes it in once, at attach).
    static func writeMemory(home: ChiefHome, plan: ChiefMigrationPlan, sources: [ChiefMigrationSource],
                            conversation: String, loggedSeq: UInt64, tool: (any ChiefMemoryTool)? = nil,
                            scratch: URL? = nil) throws -> Int {
        let fm = FileManager.default
        let optchat = home.root.appendingPathComponent("optchat", isDirectory: true)
        let chat = optchat.appendingPathComponent("chat", isDirectory: true)
        let hasMemory = fm.fileExists(atPath: optchat.appendingPathComponent("memory.sqlite3").path)
            || ((try? fm.contentsOfDirectory(atPath: chat.appendingPathComponent("main").path)) ?? []).contains { $0.hasSuffix(".jsonl") }
        if hasMemory {
            // A memory from an interrupted move: keep it; the host state must
            // still say every imported message is logged.
            if !fm.fileExists(atPath: optchat.appendingPathComponent("host.json").path) {
                try writeHostState(optchat: optchat, conversation: conversation, loggedSeq: loggedSeq)
            }
            return 0
        }
        try fm.createDirectory(at: optchat, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = (tool != nil ? scratch : nil)?.appendingPathComponent("memory", isDirectory: true) ?? chat
        let main = staging.appendingPathComponent("main", isDirectory: true)
        var entries: [ChiefMigrationSource.LogEntry] = []
        switch plan.memory {
        case .none:
            break
        case .copy(let index):
            if let text = sources[index].textDir {
                for part in ["main", "tree"] where fm.fileExists(atPath: text.appendingPathComponent(part).path) {
                    try copyRegularFiles(from: text.appendingPathComponent(part, isDirectory: true), to: staging.appendingPathComponent(part, isDirectory: true))
                }
            }
            entries = sources[index].log
            for name in ["AGENTS.md", "engine.json"] {
                let source = sources[index].muxHome.appendingPathComponent("optchat/\(name)")
                if fm.fileExists(atPath: source.path) { try? fm.copyItem(at: source, to: optchat.appendingPathComponent(name)) }
            }
        case .interleave:
            let all = sources.flatMap(\.log).sorted { ChiefMigrationPlan.time($0.date) < ChiefMigrationPlan.time($1.date) }
            try fm.createDirectory(at: main, withIntermediateDirectories: true)
            for (index, entry) in all.enumerated() {
                try append(ChiefMigrationPlan.logLine(i: index, kind: entry.kind, text: entry.text, date: entry.date), day: entry.date, in: main)
            }
            entries = all
        }
        try fm.createDirectory(at: main, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("tree", isDirectory: true), withIntermediateDirectories: true)
        for (offset, item) in plan.unlogged.enumerated() {
            let date = ChiefMigrationPlan.localDate(item.message.createdAt)
            try append(ChiefMigrationPlan.logLine(i: entries.count + offset, kind: "user", text: item.message.text, date: date), day: date, in: main)
        }
        if let tool, staging != chat, entries.count + plan.unlogged.count > 0 {
            try tool.importText(muxHome: home.muxHome, from: staging)
        }
        try writeHostState(optchat: optchat, conversation: conversation, loggedSeq: loggedSeq)
        return entries.count + plan.unlogged.count
    }

    /// `host.json`: bound to the Chief conversation with every message logged.
    private static func writeHostState(optchat: URL, conversation: String, loggedSeq: UInt64) throws {
        let state: [String: Any] = ["conversation": conversation, "logged_seq": loggedSeq, "outbox": [Any](), "turn": NSNull(),
                                    "children": [String: Any](), "orphans": [Any]()]
        let hostJSON = optchat.appendingPathComponent("host.json")
        try JSONSerialization.data(withJSONObject: state).write(to: hostJSON, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostJSON.path)
    }

    private static func append(_ line: String, day date: String, in main: URL) throws {
        let file = main.appendingPathComponent(String(date.prefix(10)) + ".jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// Copies files and directories (the git history too), skipping sockets
    /// and lock files.
    private static func copyRegularFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where !["lock", "takeover.flock"].contains(name) && !name.contains(".tmp") {
            let from = source.appendingPathComponent(name)
            let values = try from.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try copyRegularFiles(from: from, to: destination.appendingPathComponent(name))
            } else if values.isRegularFile == true {
                try fm.copyItem(at: from, to: destination.appendingPathComponent(name))
            }
        }
    }

    private static func writeRecord(_ url: URL, olds: [Old], status: String) throws {
        let record: [String: Any] = ["status": status, "at": ISO8601DateFormatter().string(from: Date()),
                                     "sources": olds.map { ["tag": $0.tag, "mux_home": $0.muxHome.path, "store": $0.store.path] }]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    // MARK: Locks

    /// The flock(2) a host holds on its `state/host.lock` for its whole life.
    final class HostLock {
        private var descriptor: Int32

        init?(path: URL) {
            descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { return nil }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                return nil
            }
        }

        func release() {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }

        deinit { release() }
    }

    /// Whether a host holds the lock at `path`. Takes it for an instant when free.
    static func lockHeld(at path: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard let lock = HostLock(path: path) else { return true }
        lock.release()
        return false
    }
}
