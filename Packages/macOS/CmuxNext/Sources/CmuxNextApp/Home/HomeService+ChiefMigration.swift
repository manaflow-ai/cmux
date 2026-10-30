import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHomeEngine
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
    /// NIGHTLY only (``ChiefHome/importsOldChiefs``): after the shared
    /// Chief home's one-time backup (``ChiefAdoption``, before the owner starts), moves the old per-tag Chiefs
    /// into it before Home or the brain host use its owner
    /// (home-state-ownership.md section 7). While an
    /// older build's host still runs, Home says so and the owner stays
    /// unpublished; the next launch tries again. Nothing is stopped. Every
    /// other build's Chief home starts empty.
    func installChiefMigration() {
        let home = chief.home
        guard home.importsOldChiefs else { return }
        let create = HomeChiefName.createRequest(user: Self.localUser, mux: Self.mux)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let olds = ChiefMigration.oldChiefs(userHome: FileManager.default.homeDirectoryForCurrentUser, applicationSupport: support)
        let logger = logger
        let tool = BundledChiefMemoryTool.bundled()
        chief.prepare = { [weak self] connection in
            // NIGHTLY's backup of the shared home exists first (taken before the owner started,
            // ChiefConversationOwner.adoption); without it the move waits for a later launch.
            guard let adoption = await self?.chief.adoption, adoption != .busy else { return }
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

    /// A conversation of the cloud owner (a cloud Chief's, or one the
    /// store lists as cloud): it does not wait for the local Chief owner.
    func isCloudConversation(_ id: ConversationID) -> Bool {
        cloudChiefs.chief(for: id.rawValue) != nil || homeStore.summary(id)?.owner == .cloud
    }

    /// The notice row of a conversation: on the local Chief, agents off in this build session (cx-tgf4h)
    /// or its organizing status while a turn waits; else the merge notice.
    func conversationNotice(for id: ConversationID) -> String? {
        let isLocalChief = HomeChiefName.select(from: conversations)?.id == id.rawValue
        // The copy notice shows where the user is: on the Hosted Chief, or on the local Chief while it keeps the tab;
        // a brain notice only on the Hosted Chief, the Chief it is about.
        if let notice = hostedChief.notice {
            let onHosted = cloudChiefs.hosted?.mainConversation == id.rawValue
            if onHosted || (hostedChief.isCopyNotice && isLocalChief && hostedChief.pending) { return notice }
        }
        return (isLocalChief ? (HomeBrainHost.agentsDisabledNotice() ?? replyNotice ?? settleNotice) : nil) ?? migrationNotice
    }

    /// What Home shows when it cannot show conversations.
    var unavailableMessage: String { migrationNotice ?? HomeStrings.unavailable }
}
