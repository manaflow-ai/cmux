import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// The Chief owner as the migration sees it: its Chief conversation (the
/// oldest with the mux, else created under the fixed key) and the import.
nonisolated struct ChiefOwnerMigrationAdapter: ChiefMigrationOwner {
    let connection: DaemonConnection
    let create: CreateConversationRequest

    func chiefConversation() async throws -> String {
        let client = ConversationClient(connection)
        if let existing = HomeChiefName.select(from: try await client.list()) { return existing.id }
        return try await client.create(create).conversation.id
    }

    func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult {
        try await ConversationClient(connection).importHistory(request)
    }
}

extension HomeService {
    /// Moves the old per-tag Chiefs into the Chief home before Home or the
    /// brain host use its owner (home-state-ownership.md section 7). While an
    /// older build's host still runs, Home says so and the owner stays
    /// unpublished; the next launch tries again. Nothing is stopped.
    func installChiefMigration() {
        let home = chief.home
        let create = HomeChiefName.createRequest(user: Self.localUser, mux: Self.mux)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let olds = ChiefMigration.oldChiefs(userHome: FileManager.default.homeDirectoryForCurrentUser, applicationSupport: support)
        let logger = logger
        let tool = BundledChiefMemoryTool.bundled()
        chief.prepare = { [weak self] connection in
            let outcome: ChiefMigration.Outcome
            do {
                outcome = try await ChiefMigration.run(home: home, owner: ChiefOwnerMigrationAdapter(connection: connection, create: create), olds: olds, tool: tool)
            } catch {
                // Soft: Home works; nothing merges (for example an owner without conversation-import).
                logger.debug("chief migration failed: \(String(describing: error), privacy: .public)")
                return
            }
            logger.info("chief migration: \(String(describing: outcome), privacy: .public)")
            let notice = ChiefMigration.notice(for: outcome)
            await MainActor.run { self?.migrationNotice = notice }
        }
    }

    /// A conversation of the cloud owner (the placed Chief's, or one the
    /// store lists as cloud): it does not wait for the local Chief owner.
    func isCloudConversation(_ id: ConversationID) -> Bool {
        cloudChief?.mainConversation == id.rawValue || homeStore.summary(id)?.owner == .cloud
    }

    /// What Home shows when it cannot show conversations.
    var unavailableMessage: String { migrationNotice ?? HomeStrings.unavailable }
}
