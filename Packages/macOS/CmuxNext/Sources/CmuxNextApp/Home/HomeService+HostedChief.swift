import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// The Hosted Chief in Home (Lawrence 2026-10-19): Cloud Chief is the default
/// and works while the user's Macs are off; this Mac's Chief is copied into it
/// once (``HostedChiefCopy``); "Chief (Mac mini)" stays one tap away.
extension HomeService {
    /// Whether this service runs Cloud Chief brains, asked once per launch
    /// (nil: unknown, asked again on the next connect).
    func hostedBrainsAvailable() async -> Bool? {
        if let known = hostedBrains { return known }
        guard let known = await HostedChiefCopy.brainsAvailable(hostedHTTP) else { return nil }
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

    /// Starts the one-time copy of this Mac's Chief into `hosted` for the
    /// signed-in account unless it ran to its end or runs now for that account
    /// (another account cancels it). While the history is not copied, the local
    /// Chief keeps the tab (``hostedPending``). A failure shows a notice and
    /// runs again on the next connect.
    func startHostedMigration(_ hosted: CloudChief?) {
        let auth = services.cloud.auth
        let user = auth.user.map { CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: $0.id) }
        if hostedMigrationUser != user {
            hostedMigration?.cancel()
            hostedMigration = nil
            hostedMigrationRun = nil
            hostedMigrationUser = nil
            setHosted(notice: nil, brainOn: nil)
        }
        let ledger = HostedChiefLedger(session: chief.home.session)
        guard let user, let hosted, let main = hosted.mainConversation else {
            hostedPending = false
            setHosted(notice: nil, brainOn: nil)
            return
        }
        // Copies by default only from a release build; a DEV build with CMUX_NEXT_HOSTED_CHIEF_COPY=1. One account per Chief home.
        let copies = (!auth.configuration.isDebugBuild || ProcessInfo.processInfo.environment["CMUX_NEXT_HOSTED_CHIEF_COPY"] == "1")
            && ledger.account.map { $0 == user } ?? true
        // The local Chief keeps the tab until the history and the memory are in (the brain is off while the memory copies).
        let memoryDue = BundledChiefMemoryTool.bundled() != nil && localMemoryExists && !ledger.done(.memory, chief: hosted.id)
        hostedPending = copies && (!ledger.done(.history, chief: hosted.id) || memoryDue)
        // Runs at every connect, also when every step is done: the brain check shows a notice when the Hosted Chief cannot answer.
        guard hostedMigration == nil else { return }
        let run = UUID()
        hostedMigrationRun = run
        hostedMigrationUser = user
        hostedMigration = Task { [weak self] in
            await self?.runHostedMigration(chief: hosted.id, main: main, user: user, copies: copies, ledger: ledger, run: run)
            guard let self, self.hostedMigrationRun == run else { return }
            self.hostedMigration = nil
            self.hostedMigrationRun = nil
        }
    }

    private func runHostedMigration(chief chiefID: String, main: String, user: String, copies: Bool,
                                    ledger: HostedChiefLedger, run: UUID) async {
        let feed = services.feed
        let copy = HostedChiefCopy(http: hostedHTTP, ops: { body in try await feed.call("v1/ops", body) }, chief: chiefID, conversation: main)
        // This run's account token, for the brain restore after a failure (the account can change meanwhile).
        let token = (try? await services.cloud.auth.tokens().access) ?? ""
        var copied = false
        var brainRead = false
        func current() throws {
            try Task.checkCancellation()
            guard hostedMigrationRun == run else { throw CancellationError() }
        }
        do {
            if copies {
                ledger.claim(account: user)
                // 1. History: the local Chief conversation into the Hosted Chief's empty main conversation.
                if !ledger.done(.history, chief: chiefID) {
                    let outcome = try await copyLocalHistory(copy)
                    try current()
                    logger.info("hosted chief history: \(String(describing: outcome), privacy: .public)")
                    if case .copied = outcome { copied = true }
                    if case .partial = outcome { copied = true }
                    ledger.mark(.history, chief: chiefID)
                }
                // 2. Memory: the store's own read-only export of this build's Chief home, never its database file.
                if !ledger.done(.memory, chief: chiefID), !localMemoryExists {
                    // A Chief home whose Chief never ran has no memory store: nothing to copy.
                    logger.info("hosted chief memory: skipped, this Chief home has no memory store")
                    ledger.mark(.memory, chief: chiefID)
                } else if !ledger.done(.memory, chief: chiefID), let tool = BundledChiefMemoryTool.bundled() {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-chief-export-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    try await tool.exportText(muxHome: chief.home.muxHome, to: folder)
                    let lines = try await HostedChiefCopy.exportLines(folder)
                    try current()
                    let outcome = try await copy.copyMemory(main: lines.main, tree: lines.tree, mayContinue: ledger.done(.memoryStarted, chief: chiefID),
                                                            started: { ledger.mark(.memoryStarted, chief: chiefID) })
                    try current()
                    logger.info("hosted chief memory: \(String(describing: outcome), privacy: .public)")
                    if case .copied = outcome { copied = true }
                    ledger.mark(.memory, chief: chiefID)
                } else if !ledger.done(.memory, chief: chiefID) {
                    // Not marked: a later build with the tool copies the memory.
                    logger.info("hosted chief memory: not copied, this build bundles no memory tool")
                }
                if hostedPending {
                    hostedPending = false
                    refreshChiefTab()
                }
            }
            // 3. The brain answers from now on: turned on once for a new Hosted Chief, or after this run turned it
            // off or copied into it. Never a silent dead Chief: a brain still off shows a notice in Home.
            var enabled = try await copy.brainEnabled()
            brainRead = true
            try current()
            if !enabled, copy.brainTurnedOff || copied || !ledger.done(.brain, chief: chiefID) {
                try await copy.setBrain(enabled: true)
                enabled = true
                try current()
            }
            if enabled { ledger.mark(.brain, chief: chiefID) }
            ledger.clearFailures(chief: chiefID)
            setHosted(notice: enabled ? nil : HostedChiefLedger.brainOffNotice, brainOn: enabled)
        } catch {
            if case FeedServiceError.owner(code: "brain_busy", message: _) = error {
                logger.info("hosted chief copy: the brain is busy, again on the next connect")
            } else if !(error is CancellationError) {
                logger.error("hosted chief \(brainRead ? "brain" : "copy", privacy: .public): \(String(describing: error), privacy: .public)")
                if hostedMigrationRun == run {
                    if brainRead {
                        // The brain was off and could not be turned on: the Chief does not answer, say so.
                        setHosted(notice: HostedChiefLedger.brainFailedNotice, brainOn: false)
                    } else if copies, HostedChiefLedger.isRefusal(error), ledger.failed(chief: chiefID) >= HostedChiefLedger.maxFailures {
                        // A copy that fails at every connect (content the server refuses) must not keep
                        // the local Chief in the tab for good: give up, log it, show the Hosted Chief.
                        logger.error("hosted chief copy: gave up after \(HostedChiefLedger.maxFailures) failed runs")
                        ledger.mark(.history, chief: chiefID)
                        ledger.mark(.memory, chief: chiefID)
                        setHosted(notice: nil, brainOn: hostedBrainOn)
                        if hostedPending {
                            hostedPending = false
                            refreshChiefTab()
                        }
                    } else if copies {
                        if HostedChiefLedger.isRefusal(error) { ledger.recordFailure(chief: chiefID) }
                        setHosted(notice: HostedChiefLedger.failedNotice, brainOn: hostedBrainOn)
                    }
                    // A brain read that failed (offline) changes nothing: the next connect reads it again.
                }
            }
            // Never leave the brain off: a cancelled run's requests are cancelled too, so this one is its own task.
            if copy.brainTurnedOff {
                // A fresh token while the account is unchanged; else this run's (the new account's cannot turn it on).
                let auth = services.cloud.auth
                let fresh: @MainActor () async throws -> String = {
                    let same = auth.user.map { CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: $0.id) } == user
                    return same ? try await auth.tokens().access : token
                }
                let restore = HostedChiefCopy(http: HostedChiefCopy.HTTP(base: copy.http.base, token: fresh), ops: copy.ops,
                                              chief: copy.chief, conversation: copy.conversation)
                // task-owner: one brain PUT, ends at once
                Task { @MainActor in try? await restore.setBrain(enabled: true) }
            }
        }
    }

    /// This build's Chief home has a memory store (a Chief that never ran has none).
    var localMemoryExists: Bool {
        FileManager.default.fileExists(atPath: chief.home.muxHome.appendingPathComponent("optchat/memory.sqlite3").path)
    }

    /// Writes the Hosted Chief's notice and brain state only when they change (no extra view updates).
    func setHosted(notice: String?, brainOn: Bool?) {
        if hostedNotice != notice { hostedNotice = notice }
        if hostedBrainOn != brainOn { hostedBrainOn = brainOn }
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

/// What this Mac's Chief home copied into which Hosted Chief, and for which
/// account (app-local; the copy steps are idempotent, so a lost record only
/// repeats skips).
@MainActor
struct HostedChiefLedger {
    enum Step: String { case history, memory, memoryStarted, brain }

    let session: String
    var defaults: UserDefaults = .standard

    /// The account this Chief home was copied for (another account does not copy it).
    var account: String? { defaults.string(forKey: "home.chief.hostedAccount.\(session)") }

    func claim(account: String) {
        if self.account == nil { defaults.set(account, forKey: "home.chief.hostedAccount.\(session)") }
    }

    func done(_ step: Step, chief: String) -> Bool { defaults.bool(forKey: key(step, chief)) }

    func mark(_ step: Step, chief: String) { defaults.set(true, forKey: key(step, chief)) }

    /// Copy runs that failed in a row; after ``maxFailures`` the copy gives up (logged).
    static let maxFailures = 3
    func failed(chief: String) -> Int { defaults.integer(forKey: "home.chief.hosted.\(session).\(chief).failures") }
    func recordFailure(chief: String) { defaults.set(failed(chief: chief) + 1, forKey: "home.chief.hosted.\(session).\(chief).failures") }
    /// The server refused the content (counts toward giving up); a network, rate or server error does not.
    static func isRefusal(_ error: any Error) -> Bool {
        guard case let FeedServiceError.owner(code, _) = error else { return false }
        return !(code.contains("rate") || code.hasPrefix("http_5") || code.hasPrefix("internal") || code.contains("unavailable") || code == "brain_busy")
    }
    func clearFailures(chief: String) { defaults.removeObject(forKey: "home.chief.hosted.\(session).\(chief).failures") }

    private func key(_ step: Step, _ chief: String) -> String { "home.chief.hosted.\(session).\(chief).\(step.rawValue)" }

    /// The import source's host: this Mac's Chief home session, as a token (ASCII 0x21-0x7e, at most 128).
    static func host(session: String) -> String {
        let token = String(String.UnicodeScalarView(session.unicodeScalars.filter { $0.value >= 0x21 && $0.value <= 0x7e }))
        return String(("mac-" + token).prefix(128))
    }

    static var brainFailedNotice: String {
        String(localized: "home.chief.hostedBrainFailed",
               defaultValue: "Your cloud Chief could not be turned on, so it does not answer yet. cmux tries again at the next launch.",
               table: "Cloud", bundle: .module)
    }

    static var brainOffNotice: String {
        String(localized: "home.chief.hostedBrainOff",
               defaultValue: "Your cloud Chief is turned off, so it does not answer messages.",
               table: "Cloud", bundle: .module)
    }

    static var failedNotice: String {
        String(localized: "home.chief.hostedCopyFailed",
               defaultValue: "Your Chief's history could not be copied to the cloud yet. cmux tries again at the next launch.",
               table: "Cloud", bundle: .module)
    }
}
