public import CmuxHomeCore
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
import os

/// The Chief's welcome (#26053): the first time this Chief home's owner connects, the Chief's own
/// conversation gets one message from the Chief with the key shortcuts (⌘P first), a few things to
/// ask it and that it answers anything about cmux, coding agents and browsers. It is written with
/// `conversation-import` under the Chief as author (a `notice:` client id, which the Chief's
/// transcript labels a host notice), so no model turn runs.
///
/// Once per Chief home: the record (`<home>/welcome.json`) says where it went. A Chief conversation
/// with history (an upgrade) is recorded without a post. Home runs it from the owner's `prepare`,
/// after the old Chiefs' migration and before Home reads the conversation, so the import never
/// lands under an open transcript and never puts the migration's older messages out of order.
/// While the welcome is the conversation's only message, Home treats the conversation as empty
/// (``Record/isOnlyMessage(of:)``): the first-run panel stays, and the Chief tab and the Hosted
/// Chief copy see no history.
public nonisolated struct ChiefWelcome: Sendable {
    /// The welcome's client message id: the owner skips a second import of it.
    public static let clientMsgID = "notice:chief-welcome-v1"
    static let recordName = "welcome.json"

    /// Where the welcome went: `seq` 0 when none was posted (the conversation had history).
    public struct Record: Codable, Sendable, Equatable {
        public var conversation: String
        public var seq: UInt64

        public init(conversation: String, seq: UInt64) {
            self.conversation = conversation
            self.seq = seq
        }

        /// Whether the welcome is all the conversation `id` (newest seq `lastSeq`) holds.
        public func isOnlyMessage(of id: String, lastSeq: UInt64) -> Bool {
            seq > 0 && id == conversation && lastSeq == seq
        }

        /// The same for a conversation of the Home store.
        public func isOnlyMessage(of summary: CmuxHomeCore.ConversationSummary) -> Bool {
            isOnlyMessage(of: summary.id.rawValue, lastSeq: summary.lastSeq)
        }
    }

    /// One shortcut line: the keys as the registry shows them (rebinds included) and the action's title.
    public struct Shortcut: Sendable, Equatable {
        public var keys: String
        public var title: String

        public init(keys: String, title: String) {
            self.keys = keys
            self.title = title
        }
    }

    /// The owner calls the welcome needs: the conversation list, the Chief conversation's
    /// idempotent creation, and the import (the seqs it gave).
    public struct Owner: Sendable {
        var list: @Sendable () async throws -> [CmuxNextDaemon.ConversationSummary]
        var create: @Sendable () async throws -> String
        var importMessages: @Sendable (ConversationImportRequest) async throws -> [UInt64]

        public init(list: @escaping @Sendable () async throws -> [CmuxNextDaemon.ConversationSummary], create: @escaping @Sendable () async throws -> String,
                    importMessages: @escaping @Sendable (ConversationImportRequest) async throws -> [UInt64]) {
            self.list = list
            self.create = create
            self.importMessages = importMessages
        }

        /// The Chief owner on `connection`; a missing Chief conversation is made by `create`, Home's request.
        public init(connection: DaemonConnection, create request: CreateConversationRequest) {
            let client = ConversationClient(connection)
            self.init(list: { try await client.list() }, create: { try await client.create(request).conversation.id },
                      importMessages: { try await client.importHistory($0).imported })
        }
    }

    let record: URL
    let chief: String
    /// The old Chiefs' migration's record (NIGHTLY, ``ChiefHome/importsOldChiefs``): until it
    /// exists the welcome waits, so the migration's older messages never come after it.
    let migration: URL?

    /// The welcome of the Chief home at `root`, written by `chief` (`agent_mux`).
    public init(root: URL, chief: String, waitsForMigration: Bool = false) {
        record = root.appendingPathComponent(Self.recordName)
        migration = waitsForMigration ? root.appendingPathComponent(ChiefMigration.recordName) : nil
        self.chief = chief
    }

    /// The welcome of `home`.
    public init(home: ChiefHome, chief: String) {
        self.init(root: home.root, chief: chief, waitsForMigration: home.importsOldChiefs)
    }

    /// The record, or nil while the welcome is still due.
    @concurrent public func load() async -> Record? {
        guard let data = try? Data(blockingContentsOf: record) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Posts the welcome (`text`, written at `at`) when due and records it. Returns the record, or
    /// nil when the owner failed: nothing is recorded, and the next connection tries again.
    @concurrent public func run(owner: Owner, text: String, at: Date = Date()) async -> Record? {
        if let done = await load() { return done }
        if let migration, !FileManager.checked.fileExists(atPath: migration.path) { return nil }
        do {
            let listed = HomeChiefName.select(from: try await owner.list())
            if let listed, listed.lastSeq > 0 { return save(Record(conversation: listed.id, seq: 0)) }
            let id: String
            if let listed { id = listed.id } else { id = try await owner.create() }
            let imported = try await owner.importMessages(Self.request(conversation: id, chief: chief, text: text, at: at))
            // Skipped: an earlier run imported it into the then empty conversation and stopped before its record.
            return save(Record(conversation: id, seq: imported.first ?? 1))
        } catch {
            return nil
        }
    }

    private func save(_ done: Record) -> Record? {
        guard let data = try? JSONEncoder().encode(done) else { return nil }
        try? FileManager.checked.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.blockingWrite(to: record, options: .atomic)) != nil else { return nil }
        return done
    }

    /// The shortcuts the welcome lists under its ⌘P call-out, in order.
    static let shortcutActions: [ActionID] = ["commandPalette", "search.chats", "newTab.default", "newSurface", "palette.newAgentChat"]
    /// The action the welcome calls out first (⌘P).
    static let goToAction: ActionID = "goToWorkspace"

    /// Runs the welcome on each connection of `owner` (its `prepare`, after the step set before,
    /// the old Chiefs' migration, and before Home attaches); `create` makes a missing Chief
    /// conversation, `report` gets the record. Isolated Chief homes (agent preflights, captures)
    /// get no welcome unless `CMUX_NEXT_CHIEF_WELCOME=1`.
    @MainActor
    public static func install(on owner: ChiefConversationOwner, registry: ActionRegistry, create: CreateConversationRequest,
                               report: @escaping @MainActor @Sendable (Record?) -> Void) {
        let home = owner.home
        guard !home.isolated || ProcessInfo.processInfo.environment["CMUX_NEXT_CHIEF_WELCOME"] == "1" else { return }
        let welcome = ChiefWelcome(home: home, chief: DaemonHomeSource.chief.id)
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
        let earlier = owner.prepare
        owner.prepare = { connection in
            if let earlier { await earlier(connection) }
            var record = await welcome.load()
            if record == nil {
                let text = await MainActor.run { Self.text(registry) }
                record = await welcome.run(owner: Owner(connection: connection, create: create), text: text)
                if record == nil { logger.info("chief welcome: not posted on this connection; the next one tries again") }
            }
            let done = record
            await MainActor.run { report(done) }
        }
    }

    /// The welcome's text with `registry`'s shortcuts (an unbound action is left out).
    @MainActor static func text(_ registry: ActionRegistry) -> String {
        let shortcuts = shortcutActions.compactMap { id -> Shortcut? in
            guard let keys = registry.shortcutDisplay(for: id), let title = registry.descriptor(for: id)?.title else { return nil }
            return Shortcut(keys: keys, title: title.hasSuffix("…") ? String(title.dropLast()) : title)
        }
        return text(goTo: registry.shortcutDisplay(for: goToAction), shortcuts: shortcuts)
    }

    /// The welcome's Markdown: ⌘P (`goTo`, nil when unbound) called out on its own, then `shortcuts`.
    public static func text(goTo: String?, shortcuts: [Shortcut]) -> String {
        var blocks = [HomeStrings.chiefWelcomeIntro]
        if let goTo { blocks.append(HomeStrings.chiefWelcomeGoTo(goTo)) }
        if !shortcuts.isEmpty {
            let lines = shortcuts.map { "- `\($0.keys)` \($0.title)" }
            blocks.append(([HomeStrings.chiefWelcomeShortcuts] + lines).joined(separator: "\n"))
        }
        blocks.append(HomeStrings.chiefWelcomeExamplesHeader + "\n" + HomeStrings.chiefWelcomeExamples)
        blocks.append(HomeStrings.chiefWelcomeAsk)
        return blocks.joined(separator: "\n\n")
    }

    /// The import of `text` into `conversation`, authored by `chief`, at `at`.
    static func request(conversation: String, chief: String, text: String, at: Date) -> ConversationImportRequest {
        let message = ConversationImportedMessage(id: nil, clientMsgID: clientMsgID, author: chief,
                                                  parts: [.object(["type": .string("text"), "text": .string(text)])],
                                                  createdAt: timestamp(at))
        return ConversationImportRequest(conversation: conversation, messages: [message])
    }

    /// The owner's time format (`YYYY-MM-DDTHH:MM:SS.mmmZ`), a millisecond back so it is never in
    /// the owner's future.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date.addingTimeInterval(-0.001))
    }
}
