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
                logger.error("chief migration failed: \(String(describing: error), privacy: .public)")
                return true
            }
            logger.info("chief migration: \(String(describing: outcome), privacy: .public)")
            if case .blocked = outcome {
                await MainActor.run { self?.migrationNotice = HomeStrings.chiefMergeBlocked }
                return false
            }
            return true
        }
    }

    /// What Home shows when it cannot show conversations.
    var unavailableMessage: String { migrationNotice ?? HomeStrings.unavailable }
}
