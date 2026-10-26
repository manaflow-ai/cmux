import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextHomeEngine
public import Foundation
public import Observation
import os

/// The Hosted Chief in Home (Lawrence 2026-10-19): Cloud Chief is the default
/// and works while the user's Macs are off; this Mac's Chief is copied into it
/// once (``HostedChiefCopy``); "Chief (Mac mini)" stays one tap away. The app's
/// HomeService wires it (``Wiring``) and starts it at every connect.
@Observable @MainActor
public final class HostedChiefMigration {
    /// What the app gives: the API Worker as the signed-in user, the account, this build's Chief home and its history.
    public struct Wiring {
        public var apiBase: @MainActor () -> URL
        public var token: @MainActor () async throws -> String
        /// `v1/ops` as the signed-in user; a refusal throws ``HostedChiefError/owner(code:message:)``.
        public var ops: @MainActor (_ body: [String: Any]) async throws -> [String: Any]
        /// The signed-in account's worker user id, nil when signed out.
        public var user: @MainActor () -> String?
        /// A release build copies by default; a DEV build only with CMUX_NEXT_HOSTED_CHIEF_COPY=1.
        public var copies: Bool
        /// The Chief tab follows a change of ``pending`` or of ``choice``.
        public var refreshTab: @MainActor () -> Void
        /// This build's Chief home's owner: its session (the ledger key), mux home (the memory store) and history.
        public var owner: ChiefConversationOwner
        /// The local Chief's participant id (`agent_mux`).
        public var localChief: String

        public init(apiBase: @escaping @MainActor () -> URL, token: @escaping @MainActor () async throws -> String,
                    ops: @escaping @MainActor (_ body: [String: Any]) async throws -> [String: Any], user: @escaping @MainActor () -> String?,
                    debugBuild: Bool, owner: ChiefConversationOwner, localChief: String,
                    refreshTab: @escaping @MainActor () -> Void) {
            self.apiBase = apiBase
            self.token = token
            self.ops = ops
            self.user = user
            self.copies = !debugBuild || ProcessInfo.processInfo.environment["CMUX_NEXT_HOSTED_CHIEF_COPY"] == "1"
            self.owner = owner
            self.localChief = localChief
            self.refreshTab = refreshTab
        }
    }

    enum LocalHistory {
        case none(String)
        case messages([ConversationMessage], localID: String)
    }

    /// The cloud Chief the Chief tab shows (``HomeChiefChoice``, kept on this Mac).
    public private(set) var choice = HomeChiefChoice.load()
    /// This Mac's Chief is not in the Hosted Chief yet: the local Chief keeps the tab.
    public private(set) var pending = false
    /// Shown on the Hosted Chief's conversation while its copy failed or its brain is off.
    public private(set) var notice: String?
    /// The Hosted Chief's brain is on (nil: not read yet this launch).
    public private(set) var brainOn: Bool?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var runUser: String?
    @ObservationIgnored private var brains: Bool?
    @ObservationIgnored private var wiring: Wiring?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init() {}

    public func wire(_ wiring: Wiring) { self.wiring = wiring }

    /// The Chief tab shows `choice` from now on (the switch's tap).
    public func pick(_ choice: HomeChiefChoice) {
        guard self.choice != choice else { return }
        self.choice = choice
        choice.save()
        wiring?.refreshTab()
    }

    /// A copy or brain check runs now (debug).
    public var running: Bool { task != nil }

    /// The copy notice: shown on the local Chief too while it keeps the tab.
    public var isCopyNotice: Bool { notice == HomeCloudChiefs.copyFailed }

    private var http: HostedChiefCopy.HTTP? {
        guard let wiring else { return nil }
        return HostedChiefCopy.HTTP(base: wiring.apiBase(), token: wiring.token)
    }

    /// The Cloud Chief brain route as the signed-in user, for a hosted Chief's settings card
    /// (``HomeChiefHostedEngine``): signed out (or no token) throws its `signedOut`.
    public var brainRoute: HomeChiefHostedEngine.Send {
        { [weak self] method, path, body in
            guard let self, let wiring, wiring.user() != nil, let http else { throw HomeChiefHostedEngine.Failure.signedOut }
            let token: String
            do { token = try await wiring.token() } catch { throw HomeChiefHostedEngine.Failure.signedOut }
            return try await HostedChiefCopy.HTTP(base: http.base, token: { token }).send(method, path, data: body)
        }
    }

    /// Turns on the brain of a hosted Chief the user just made (New Chief): a new Chief's brain
    /// starts off, and one left off never answers. A service with no Chief brains is left alone.
    /// Whether it is on; a failure is logged.
    @discardableResult
    public func enableBrain(of chief: String) async -> Bool {
        guard let wiring, let http, await brainsAvailable() == true else { return false }
        do {
            try await HostedChiefCopy(http: http, ops: wiring.ops, chief: chief, conversation: "").setBrain(enabled: true)
            return true
        } catch {
            logger.error("hosted chief: a new Chief's brain could not be turned on: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Whether this service runs Cloud Chief brains, asked once per launch (nil: unknown, asked again on the next connect).
    public func brainsAvailable() async -> Bool? {
        if let brains { return brains }
        guard let http, let known = await HostedChiefCopy.brainsAvailable(http) else { return nil }
        brains = known
        return known
    }

    /// The ledger's steps for `chief` and the account this Chief home copied for (debug).
    public func ledger(chief: String) -> (steps: [String: Bool], account: String?) {
        guard let wiring else { return ([:], nil) }
        let ledger = HostedChiefLedger(session: wiring.owner.home.session)
        let steps = [HostedChiefLedger.Step.history, .memory, .brain].map { ($0.rawValue, ledger.done($0, chief: chief)) }
        return (Dictionary(uniqueKeysWithValues: steps), ledger.account)
    }

    /// Starts the one-time copy of this Mac's Chief into `hosted` for the
    /// signed-in account, and the brain check (every connect: a brain that
    /// is off shows a notice). Another account cancels a run. While the
    /// history and the memory are not in, the local Chief keeps the tab
    /// (``pending``). A failure shows a notice and runs again on the next connect.
    public func start(_ hosted: CloudChief?) {
        guard let wiring else { return }
        let user = wiring.user()
        if runUser != user {
            task?.cancel()
            task = nil
            runID = nil
            runUser = nil
            set(notice: nil, brainOn: nil)
        }
        let home = wiring.owner.home
        let ledger = HostedChiefLedger(session: home.session)
        guard let user, let hosted, let main = hosted.mainConversation else {
            pending = false
            set(notice: nil, brainOn: nil)
            return
        }
        // One account per Chief home.
        let copies = wiring.copies && ledger.account.map { $0 == user } ?? true
        // The local Chief keeps the tab until the history and the memory are in (the brain is off while the memory copies).
        let memoryDue = BundledChiefMemoryTool.bundled() != nil && Self.memoryExists(home.muxHome) && !ledger.done(.memory, chief: hosted.id)
        pending = copies && (!ledger.done(.history, chief: hosted.id) || memoryDue)
        guard task == nil, let http else { return }
        let run = UUID()
        runID = run
        runUser = user
        let copy = HostedChiefCopy(http: http, ops: wiring.ops, chief: hosted.id, conversation: main)
        task = Task { [weak self] in
            await self?.run(copy, user: user, copies: copies, ledger: ledger, muxHome: home.muxHome, run: run)
            guard let self, self.runID == run else { return }
            self.task = nil
            self.runID = nil
        }
    }

    private func run(_ copy: HostedChiefCopy, user: String, copies: Bool, ledger: HostedChiefLedger, muxHome: URL, run: UUID) async {
        guard let wiring else { return }
        let chiefID = copy.chief
        // This run's account token, for the brain restore after a failure (the account can change meanwhile).
        let token = (try? await wiring.token()) ?? ""
        var copied = false
        var brainRead = false
        func current() throws {
            try Task.checkCancellation()
            guard runID == run else { throw CancellationError() }
        }
        do {
            if copies {
                ledger.claim(account: user)
                // 1. History: the local Chief conversation into the Hosted Chief's empty main conversation.
                if !ledger.done(.history, chief: chiefID) {
                    let outcome = try await copyHistory(copy, user: user, session: ledger.session)
                    try current()
                    logger.info("hosted chief history: \(String(describing: outcome), privacy: .public)")
                    if case .copied = outcome { copied = true }
                    if case .partial = outcome { copied = true }
                    ledger.mark(.history, chief: chiefID)
                }
                // 2. Memory: the store's own read-only export of this build's Chief home, never its database file.
                if !ledger.done(.memory, chief: chiefID), !Self.memoryExists(muxHome) {
                    // A Chief home whose Chief never ran has no memory store: nothing to copy.
                    logger.info("hosted chief memory: skipped, this Chief home has no memory store")
                    ledger.mark(.memory, chief: chiefID)
                } else if !ledger.done(.memory, chief: chiefID), let tool = BundledChiefMemoryTool.bundled() {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-chief-export-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    try await tool.exportText(muxHome: muxHome, to: folder)
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
                settle()
            }
            // 3. The brain answers from now on: turned on only for a Hosted Chief this Home just created, or after
            // this run turned it off or copied into it. A brain the user turned off stays off, and Home says so:
            // never a silent dead Chief.
            var enabled = try await copy.brainEnabled()
            brainRead = true
            try current()
            if !enabled, copy.brainTurnedOff || copied || HomeCloudChiefs.createdHere(chiefID) {
                try await copy.setBrain(enabled: true)
                enabled = true
                try current()
            }
            if enabled {
                ledger.mark(.brain, chief: chiefID)
                HomeCloudChiefs.createdHere(chiefID, false)
            }
            ledger.clearFailures(chief: chiefID)
            set(notice: enabled ? nil : HomeCloudChiefs.brainOff, brainOn: enabled)
        } catch {
            if case HostedChiefError.owner(code: "brain_busy", message: _) = error {
                logger.info("hosted chief copy: the brain is busy, again on the next connect")
            } else if !(error is CancellationError) {
                logger.error("hosted chief \(brainRead ? "brain" : "copy", privacy: .public): \(String(describing: error), privacy: .public)")
                if runID == run {
                    if brainRead {
                        // The brain was off and could not be turned on: the Chief does not answer, say so.
                        set(notice: HomeCloudChiefs.brainFailed, brainOn: false)
                    } else if copies, HostedChiefLedger.isRefusal(error), ledger.failed(chief: chiefID) >= HostedChiefLedger.maxFailures {
                        // A copy that fails at every connect (content the server refuses) must not keep
                        // the local Chief in the tab for good: give up, log it, show the Hosted Chief.
                        logger.error("hosted chief copy: gave up after \(HostedChiefLedger.maxFailures) failed runs")
                        ledger.mark(.history, chief: chiefID)
                        ledger.mark(.memory, chief: chiefID)
                        set(notice: nil, brainOn: brainOn)
                        settle()
                    } else if copies {
                        if HostedChiefLedger.isRefusal(error) { ledger.recordFailure(chief: chiefID) }
                        set(notice: HomeCloudChiefs.copyFailed, brainOn: brainOn)
                    }
                    // A brain read that failed (offline) changes nothing: the next connect reads it again.
                }
            }
            // Never leave the brain off: a cancelled run's requests are cancelled too, so this one is its own task.
            if copy.brainTurnedOff {
                // A fresh token while the account is unchanged; else this run's (the new account's cannot turn it on).
                let fresh: @MainActor () async throws -> String = { wiring.user() == user ? try await wiring.token() : token }
                let restore = HostedChiefCopy(http: HostedChiefCopy.HTTP(base: copy.http.base, token: fresh), ops: copy.ops,
                                              chief: copy.chief, conversation: copy.conversation)
                // task-owner: one brain PUT, ends at once
                Task { @MainActor in try? await restore.setBrain(enabled: true) }
            }
        }
    }

    /// The history and the memory are in: the Hosted Chief takes the tab.
    private func settle() {
        guard pending else { return }
        pending = false
        wiring?.refreshTab()
    }

    private func copyHistory(_ copy: HostedChiefCopy, user: String, session: String) async throws -> HostedChiefCopy.HistoryOutcome {
        guard let wiring else { return .skipped("unwired") }
        switch try await Self.localHistory(wiring.owner) {
        case let .none(reason):
            return .skipped(reason)
        case let .messages(messages, localID):
            let mapped = HostedChiefCopy.importMessages(messages, user: user, chief: copy.chief, localChief: wiring.localChief)
            return try await copy.copyHistory(mapped, host: HostedChiefLedger.host(session: session), localID: localID)
        }
    }

    /// The local Chief conversation's messages, read from the Chief home's owner.
    private static func localHistory(_ owner: ChiefConversationOwner) async throws -> LocalHistory {
        var connection: DaemonConnection?
        for await next in ObservationStream({ owner.supports(DaemonCapability.localConversations.rawValue) ? owner.connection : nil }) {
            if let next { connection = next; break }
        }
        guard let connection else { return .none("no_owner") }
        let client = ConversationClient(connection)
        guard let local = HomeChiefName.select(from: try await client.list()), local.lastSeq > 0 else { return .none("no_local_history") }
        var messages: [ConversationMessage] = []
        var before = local.lastSeq + 1
        for _ in 0..<10_000 {
            let page = try await client.history(local.id, before: before, limit: 500)
            guard let first = page.first else { break }
            messages.insert(contentsOf: page, at: 0)
            before = first.seq
            if first.seq <= 1 { break }
        }
        return .messages(messages, localID: local.id)
    }

    /// The Hosted Chief proof's view (`debug.home` `hosted_chief`): the tab's Chiefs, the choice, the ledger and the brain.
    public func debugState(cloud: HomeCloudChiefs, tab: HomeCloudChiefs, shown: String?) -> [String: Any] {
        func chief(_ chief: CloudChief?) -> Any {
            guard let chief else { return NSNull() }
            return ["id": chief.id, "name": chief.displayName, "default": chief.isDefault,
                    "main": chief.mainConversation ?? NSNull(), "placed": chief.brainPlace != nil] as [String: Any]
        }
        let ledger = cloud.hosted.map { self.ledger(chief: $0.id) }
        return ["hosted": chief(cloud.hosted), "placed": chief(cloud.placed), "choice": choice.rawValue, "can_switch": tab.canSwitch,
                "shown": shown ?? NSNull(), "pending": pending, "running": running, "brain_on": brainOn ?? NSNull(),
                "notice": notice ?? NSNull(), "ledger": ledger?.steps ?? NSNull(), "account": ledger?.account ?? NSNull()]
    }

    /// The Chief home has a memory store (a Chief that never ran has none).
    private static func memoryExists(_ muxHome: URL) -> Bool {
        FileManager.default.fileExists(atPath: muxHome.appendingPathComponent("optchat/memory.sqlite3").path)
    }

    /// Writes the notice and the brain state only when they change (no extra view updates).
    private func set(notice: String?, brainOn: Bool?) {
        if self.notice != notice { self.notice = notice }
        if self.brainOn != brainOn { self.brainOn = brainOn }
    }
}
