public import CmuxNextDaemon
import Darwin
public import Foundation
import SQLite3

/// What the Chief owner does for the migration: the Chief conversation and
/// the `conversation-import` command.
public protocol ChiefMigrationOwner: Sendable {
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
public nonisolated enum ChiefMigration {
    public enum Outcome: Sendable, Equatable {
        case done(messages: Int, memoryEntries: Int)
        /// Nothing to move, or already moved, or an isolated home.
        case nothingToDo
        /// Old hosts still run (their tags); retried at the next launch.
        case blocked([String])
        /// The owner refused the history (it already holds newer messages).
        case refused(String)
    }

    public struct Old: Sendable, Equatable {
        var tag: String
        var muxHome: URL
        var store: URL
    }

    static let recordName = "migration.json"

    /// Home's one-line notice for `outcome`, if any.
    public static func notice(for outcome: Outcome) -> String? {
        if case .blocked = outcome { return HomeStrings.chiefMergeBlocked }
        return nil
    }

    private struct StepRequest: Encodable { let isolated, recordExists: Bool; let blocking: [String] }
    private struct StepReply: Decodable { let step: String }

    /// The rules' `migration::Old`.
    private struct WireOld: Codable {
        var tag: String
        var muxHome: String
        var store: String
    }

    /// Every old per-tag Chief on this Mac: `~/.cmux/mux/tags/<tag>` and the
    /// tag daemon's conversation store, under `cmux-next/tags/<tag>` once that
    /// build moved its folder (StateFolderMove), else under classic's `cmux/tags/<tag>`.
    /// Which store is the tag's is cmux-home-rules `chief_home.migration_old_chiefs`;
    /// this lists the tags and the moved stores that are there. Empty if the
    /// rules fail (`run` then throws at its first rules call, so no record is written).
    public static func oldChiefs(userHome: URL, applicationSupport: URL) -> [Old] {
        struct Request: Encodable { let userHome, applicationSupport: String; let tags, existing: [String] }
        struct Reply: Decodable { let olds: [WireOld] }
        let fm = FileManager.default
        let tags = (try? fm.contentsOfDirectory(atPath: userHome.appendingPathComponent(".cmux/mux/tags", isDirectory: true).path)) ?? []
        let moved = applicationSupport.standardizedFileURL.appendingPathComponent("cmux-next/tags", isDirectory: true)
        let existing = tags.flatMap { tag in
            let tui = moved.appendingPathComponent("\(tag)/tui", isDirectory: true)
            return ((try? fm.contentsOfDirectory(atPath: tui.path)) ?? []).map { tui.appendingPathComponent("\($0)/conversations.sqlite3").path }
                .filter { FileManager.checked.fileExists(atPath: $0) }
        }
        let reply: Reply? = try? ChiefHomeRules().call("migration_old_chiefs", Request(
            userHome: userHome.path, applicationSupport: applicationSupport.path, tags: tags, existing: existing))
        return (reply?.olds ?? []).map { old in
            Old(tag: old.tag, muxHome: URL(fileURLWithPath: old.muxHome, isDirectory: true), store: URL(fileURLWithPath: old.store))
        }
    }

    /// Runs the move for `home`. Idempotent: a finished move is recorded in
    /// `<home>/migration.json`, and the owner skips what it already holds.
    @concurrent public static func run(home: ChiefHome, owner: some ChiefMigrationOwner, olds: [Old], tool: (any ChiefMemoryTool)? = nil) async throws -> Outcome {
        let record = home.root.appendingPathComponent(recordName)
        func step(_ blocking: [String]) throws -> String {
            let reply: StepReply = try ChiefHomeRules().call("migration_run_step", StepRequest(
                isolated: home.isolated, recordExists: FileManager.default.fileExists(atPath: record.path), blocking: blocking))
            return reply.step
        }
        if try step([]) == "nothingToDo" { return .nothingToDo }
        // Old hosts' locks only once the move would run (lockHeld takes a free lock for an instant).
        let blocking = olds.filter { lockHeld(at: $0.muxHome.appendingPathComponent("state/host.lock")) }.map(\.tag)
        if try step(blocking) == "blocked" { return .blocked(blocking) }
        let lockPath = home.root.appendingPathComponent("state/host.lock")
        try FileManager.default.createDirectory(at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let lock = HostLock(path: lockPath) else { return .blocked([home.root.lastPathComponent]) }
        defer { lock.release() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chief-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var sources: [ChiefMigrationSource] = []
        for old in olds { if let source = await readSource(old, tool: tool, scratch: scratch) { sources.append(source) } }
        let plan = try ChiefMigrationPlan.make(sources)
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
            let entries = try await writeMemory(home: home, plan: plan, sources: sources, conversation: conversation,
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
                            scratch: URL? = nil) async throws -> Int {
        let fm = FileManager.default
        let optchat = home.root.appendingPathComponent("optchat", isDirectory: true)
        let chat = optchat.appendingPathComponent("chat", isDirectory: true)
        struct HasMemoryRequest: Encodable { let databaseExists: Bool; let mainNames: [String] }
        struct HasMemoryReply: Decodable { let hasMemory: Bool }
        let hasMemory: HasMemoryReply = try ChiefHomeRules().call("migration_has_memory", HasMemoryRequest(
            databaseExists: fm.fileExists(atPath: optchat.appendingPathComponent("memory.sqlite3").path),
            mainNames: (try? fm.contentsOfDirectory(atPath: chat.appendingPathComponent("main").path)) ?? []))
        if hasMemory.hasMemory {
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
        if case .copy(let index) = plan.memory {
            if let text = sources[index].textDir {
                for part in ["main", "tree"] where fm.fileExists(atPath: text.appendingPathComponent(part).path) {
                    try copyRegularFiles(from: text.appendingPathComponent(part, isDirectory: true), to: staging.appendingPathComponent(part, isDirectory: true))
                }
            }
            for name in ["AGENTS.md", "engine.json"] {
                let source = sources[index].muxHome.appendingPathComponent("optchat/\(name)")
                if fm.fileExists(atPath: source.path) { try? fm.copyItem(at: source, to: optchat.appendingPathComponent(name)) }
            }
        }
        try fm.createDirectory(at: main, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("tree", isDirectory: true), withIntermediateDirectories: true)
        let lines = try memoryLines(plan: plan, sources: sources)
        for line in lines.appends { try append(line.line, file: line.file, in: main) }
        if let tool, staging != chat, lines.entries > 0 {
            try await tool.importText(muxHome: home.muxHome, from: staging)
        }
        try writeHostState(optchat: optchat, conversation: conversation, loggedSeq: loggedSeq)
        return lines.entries
    }

    private struct MemoryLines: Decodable {
        struct Append: Decodable {
            let file: String
            let line: String
        }
        var appends: [Append]
        var entries: Int
    }

    /// The memory's lines (cmux-home-rules `chief_home.migration_memory`): the
    /// interleaved old logs, then each unlogged human message as a `user` line
    /// dated in this Mac's time zone at that message's instant (daylight saving
    /// per date: one rules call per distinct offset).
    private static func memoryLines(plan: ChiefMigrationPlan, sources: [ChiefMigrationSource]) throws -> MemoryLines {
        struct Request: Encodable { let sources: [ChiefMigrationSource.Wire]; let utcOffsetSeconds: Int; let unloggedOffsets: [Int] }
        struct TimeRequest: Encodable { let text: String }
        struct TimeReply: Decodable { let seconds: Double }
        let offsets = try plan.unlogged.map { item in
            let time: TimeReply = try ChiefHomeRules().call("migration_time", TimeRequest(text: item.message.createdAt))
            return TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: time.seconds))
        }
        return try ChiefHomeRules().call("migration_memory", Request(
            sources: sources.map(\.wire), utcOffsetSeconds: offsets.first ?? TimeZone.current.secondsFromGMT(),
            unloggedOffsets: offsets))
    }

    /// `host.json`: bound to the Chief conversation with every message logged.
    private static func writeHostState(optchat: URL, conversation: String, loggedSeq: UInt64) throws {
        struct Request: Encodable { let conversation: String; let loggedSeq: UInt64 }
        struct Reply: Decodable { let json: String }
        let state: Reply = try ChiefHomeRules().call("migration_host_state", Request(conversation: conversation, loggedSeq: loggedSeq))
        let hostJSON = optchat.appendingPathComponent("host.json")
        try Data(state.json.utf8).write(to: hostJSON, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostJSON.path)
    }

    private static func append(_ line: String, file name: String, in main: URL) throws {
        let file = main.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// Copies files and directories (the git history too), skipping sockets
    /// and the lock and temporary files (`chief_home.migration_copy_skips`).
    private static func copyRegularFiles(from source: URL, to destination: URL) throws {
        struct Request: Encodable { let name: String }
        struct Reply: Decodable { let skip: Bool }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let skips: Reply = try ChiefHomeRules().call("migration_copy_skips", Request(name: name))
            if skips.skip { continue }
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
        struct Request: Encodable { let status: String; let now: Double; let olds: [WireOld] }
        struct Reply: Decodable { let json: String }
        let record: Reply = try ChiefHomeRules().call("migration_record", Request(
            status: status, now: Date().timeIntervalSince1970,
            olds: olds.map { WireOld(tag: $0.tag, muxHome: $0.muxHome.path, store: $0.store.path) }))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(record.json.utf8).write(to: url, options: .atomic)
    }

    // MARK: Locks

    /// The flock(2) a host holds on its `state/host.lock` for its whole life.
    nonisolated final class HostLock {
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
