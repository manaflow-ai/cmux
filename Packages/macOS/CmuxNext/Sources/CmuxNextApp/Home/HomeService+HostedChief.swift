import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// The Hosted Chief in Home (Lawrence 2026-10-19): Cloud Chief is the default
/// and works while the user's Macs are off; this Mac's Chief is copied into it
/// once (``HostedChiefCopy``); "Chief (Mac mini)" stays one tap away.
extension HomeService {
    /// Whether this service runs Cloud Chief brains, asked once per launch
    /// (an unknown answer is asked again on the next connect).
    func hostedBrainsAvailable() async -> Bool {
        if let known = hostedBrains { return known }
        guard let known = await HostedChiefCopy.brainsAvailable(hostedHTTP) else { return false }
        hostedBrains = known
        return known
    }

    var hostedHTTP: HostedChiefCopy.HTTP {
        let auth = services.cloud.auth
        return HostedChiefCopy.HTTP(base: services.feed.apiBaseURL, token: { try await auth.tokens().access })
    }

    /// The Chief tab shows `choice` (``HomeChiefChoice``, kept on this Mac).
    func switchChief(to choice: HomeChiefChoice) {
        guard chiefChoice != choice else { return }
        chiefChoice = choice
        choice.save()
        refreshChiefTab()
    }

    /// Starts the one-time copy of this Mac's Chief into `hosted` unless it
    /// ran to its end for that chief or runs now. A failure shows a notice on
    /// the Hosted Chief's conversation and runs again on the next connect.
    func startHostedMigration(_ hosted: CloudChief?) {
        guard let hosted, let main = hosted.mainConversation, hostedMigration == nil,
              !HostedChiefLedger.isDone(chief: hosted.id), services.cloud.auth.isSignedIn else { return }
        hostedMigration = Task { [weak self] in
            await self?.runHostedMigration(chief: hosted.id, main: main)
            self?.hostedMigration = nil
        }
    }

    private func runHostedMigration(chief chiefID: String, main: String) async {
        let feed = services.feed
        let copy = HostedChiefCopy(http: hostedHTTP, ops: { body in try await feed.call("v1/ops", body) }, chief: chiefID, conversation: main)
        do {
            // 1. Memory: the store's own read-only export of this build's Chief home, never its database file.
            if let tool = BundledChiefMemoryTool.bundled() {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-chief-export-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                try await tool.exportText(muxHome: chief.home.muxHome, to: folder)
                let lines = try await HostedChiefCopy.exportLines(folder)
                let outcome = try await copy.copyMemory(main: lines.main, tree: lines.tree)
                logger.info("hosted chief memory: \(String(describing: outcome), privacy: .public)")
            } else {
                logger.info("hosted chief memory: skipped, this build bundles no memory tool")
            }
            // 2. History: the local Chief conversation into the Hosted Chief's empty main conversation.
            let outcome = try await copyLocalHistory(copy)
            logger.info("hosted chief history: \(String(describing: outcome), privacy: .public)")
            // 3. The brain answers from now on.
            if !(try await copy.brainEnabled()) { try await copy.setBrain(enabled: true) }
            HostedChiefLedger.markDone(chief: chiefID)
            hostedNotice = nil
        } catch is CancellationError {
        } catch {
            logger.error("hosted chief copy: \(String(describing: error), privacy: .public)")
            hostedNotice = HostedChiefLedger.failedNotice
        }
    }

    private func copyLocalHistory(_ copy: HostedChiefCopy) async throws -> HostedChiefCopy.HistoryOutcome {
        let auth = services.cloud.auth
        guard let stackUser = auth.user?.id else { return .skipped("signed_out") }
        let owner = chief
        var connection: DaemonConnection?
        for await next in ObservationStream({ owner.supports(DaemonCapabilities.shared.localConversations) ? owner.connection : nil }) {
            if let next { connection = next; break }
        }
        guard let connection else { return .skipped("no_owner") }
        let client = ConversationClient(connection)
        guard let local = HomeChiefName.select(from: try await client.list()), local.lastSeq > 0 else { return .skipped("no_local_history") }
        var messages: [ConversationMessage] = []
        var before = local.lastSeq + 1
        for _ in 0..<10_000 {
            let page = try await client.history(local.id, before: before, limit: 500)
            guard let first = page.first else { break }
            messages.insert(contentsOf: page, at: 0)
            before = first.seq
            if first.seq <= 1 { break }
        }
        let user = CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: stackUser)
        let mapped = HostedChiefCopy.importMessages(messages, user: user, chief: copy.chief, localChief: Self.mux.id)
        return try await copy.copyHistory(mapped, host: HostedChiefLedger.host(session: owner.home.session), localID: local.id)
    }
}

/// Which Hosted Chiefs this Mac copied its Chief into (app-local; the copy
/// steps are idempotent, so a lost record only repeats skips).
@MainActor
enum HostedChiefLedger {
    private static func key(_ chief: String) -> String { "home.chief.hostedCopied.\(chief)" }

    static func isDone(chief: String, _ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key(chief)) }

    static func markDone(chief: String, _ defaults: UserDefaults = .standard) { defaults.set(true, forKey: key(chief)) }

    /// The import source's host: this Mac's Chief home session, as a token (ASCII 0x21-0x7e, at most 128).
    static func host(session: String) -> String {
        let token = String(String.UnicodeScalarView(session.unicodeScalars.filter { $0.value >= 0x21 && $0.value <= 0x7e }))
        return String(("mac-" + token).prefix(128))
    }

    static var failedNotice: String {
        String(localized: "home.chief.hostedCopyFailed",
               defaultValue: "Your Chief's history could not be copied to the cloud yet. cmux tries again at the next launch.",
               table: "Cloud", bundle: .module)
    }
}
