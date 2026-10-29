import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextWakeups
import Foundation
import os

/// The palette's usage history as the home daemon owns it
/// (`palette-usage-v1`, plans/cmux-next/palette-ranking.md 5.3): one writer
/// for every client, stamped with the daemon's clock, local to this Mac.
/// This side keeps a read mirror for the ranker and sends each run, then
/// rereads the history (record results carry only the revision). With a
/// daemon that lacks the capability the former local history is kept as
/// before (no learned picks); while the daemon is away a run is dropped,
/// never written to a second store.
///
/// The daemon calls run off main, in one nonisolated task per fetch or per batch of writes; only their
/// replies are main-thread tasks on ``MainWorkScheduler`` (p06 recipe R-hop), as Chromium posts a
/// thread-pool reply back to the UI thread (`base::PostTaskAndReplyWithResult`, base/task/post_task.h).
@MainActor
final class DaemonPaletteUsageStore: PaletteUsageStore {
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.usage")

    private weak var services: AppServices?
    /// The app's main-thread scheduler: a fetch's and a batch's replies are posted tasks on it.
    private let mainWork: MainWorkScheduler
    /// The app's blocking-work lanes: the former histories are read there.
    private let work: BackgroundWork
    private let local: LocalPaletteUsageStore
    private let preferences: URL
    /// The connection whose former histories were imported this launch.
    private var importedOn: ObjectIdentifier?
    /// The revision of the mirror; an older snapshot never replaces it.
    private var revision: UInt64 = 0
    private var fetching: Task<Void, Never>?
    private var fetchAgain = false
    /// One write to the daemon's history.
    private nonisolated enum Write: Sendable {
        case record(key: String, query: String)
        case hide(key: String, hidden: Bool)
        case forget(key: String)
    }

    /// Writes waiting to be sent, oldest first, and the one task that sends
    /// them in order (cancelled with the store).
    private var pendingRuns: [(write: Write, idempotencyKey: String)] = []
    private var recorder: Task<Void, Never>?
    private(set) var history: FrecencyStore
    var onChange: (@MainActor () -> Void)?

    init(services: AppServices, mainWork: MainWorkScheduler,
         local: LocalPaletteUsageStore = LocalPaletteUsageStore(persistence: UserDefaultsFrecencyPersistence()),
         preferences: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")) {
        self.services = services
        self.mainWork = mainWork
        work = services.work
        self.local = local
        self.preferences = preferences
        history = local.history
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        recorder?.cancel()
        fetching?.cancel()
    }

    private enum Owner {
        case daemon(PaletteUsageStateClient, ObjectIdentifier)
        /// Connected to a daemon without `palette-usage-v1`.
        case local
        case away
    }

    private var owner: Owner {
        guard let daemon = services?.machines.local, let connection = daemon.connection else { return .away }
        guard daemon.supports(DaemonCapability.paletteUsage.rawValue) else { return .local }
        return .daemon(PaletteUsageStateClient(connection: connection), ObjectIdentifier(connection))
    }

    func prepare() {
        guard case .daemon(_, let id) = owner else { return }
        if importedOn != id || revision == 0 { fetch() }
    }

    /// Rereads the history (one fetch at a time; a request during one runs
    /// one more after it). The first fetch on a connection imports the former
    /// per-build histories the daemon has not seen, each on its own.
    private func fetch() {
        guard fetching == nil else {
            fetchAgain = true
            return
        }
        guard case .daemon(let client, let id) = owner else { return }
        let importing = importedOn != id, preferences = preferences, mainWork = mainWork, work = work
        // task-owner: DaemonPaletteUsageStore.fetching (cancelled with the store); one read, off main (recipe R-hop)
        fetching = Task { @concurrent [weak self] in
            let answer = await Self.read(client, importing: importing, preferences: preferences, work: work)
            guard !Task.isCancelled else { return }
            // `visible`: an open palette reranks with what it reads; no input of the person waits on it.
            mainWork.postFromAnyThread(.visible, owner: "DaemonPaletteUsageStore.fetched") { [weak self] in
                self?.fetched(answer, on: id)
            }
        }
    }

    /// One fetch's answer: the history, and whether this connection's former histories were imported.
    private nonisolated struct Fetched: Sendable {
        var history: FrecencyStore
        var revision: UInt64
        var imported: Bool
    }

    /// Reads the daemon's history, importing first (when `importing`) each former history it has not seen.
    @concurrent private nonisolated static func read(_ client: PaletteUsageStateClient, importing: Bool,
                                                     preferences: URL, work: BackgroundWork) async -> Fetched? {
        do {
            var snapshot = try PaletteUsageWire.history(try await client.get())
            guard importing else { return Fetched(history: snapshot.history, revision: snapshot.revision, imported: false) }
            var importedAny = false
            for former in await PaletteUsageLegacyHistory.read(preferences: preferences, runner: work)
            where !snapshot.imported.contains(former.source) && !Task.isCancelled {
                do {
                    _ = try await client.importHistory(source: former.source, entries: former.rows,
                                                       idempotencyKey: "palette-usage-import:\(former.source)")
                    importedAny = true
                } catch {
                    logger.error("palette usage import of one former history failed: \(String(describing: error), privacy: .public)")
                }
            }
            if importedAny { snapshot = try PaletteUsageWire.history(try await client.get()) }
            return Fetched(history: snapshot.history, revision: snapshot.revision, imported: true)
        } catch {
            logger.error("palette usage fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The fetch's reply on main: keeps a newer history, then runs the fetch asked for while it ran.
    private func fetched(_ answer: Fetched?, on connection: ObjectIdentifier) {
        fetching = nil
        if let answer {
            if answer.imported { importedOn = connection }
            if answer.revision >= revision {
                revision = answer.revision
                history = answer.history
                onChange?()
            }
        }
        if fetchAgain {
            fetchAgain = false
            fetch()
        }
    }

    func recordUse(key: String, query: String, at now: Date) {
        switch owner {
        case .local:
            local.recordUse(key: key, query: query, at: now)
            history = local.history
        case .away:
            Self.logger.info("palette usage: daemon away, one run not recorded")
        case .daemon:
            enqueue(.record(key: key, query: query))
        }
    }

    var canHideRows: Bool {
        if case .daemon = owner { return true }
        return false
    }

    func setHidden(key: String, hidden: Bool) {
        guard case .daemon = owner else { return }
        enqueue(.hide(key: key, hidden: hidden))
    }

    func forget(key: String) {
        switch owner {
        case .local:
            local.forget(key: key)
            history = local.history
        case .away:
            Self.logger.info("palette usage: daemon away, Reset Ranking not sent")
        case .daemon:
            enqueue(.forget(key: key))
        }
    }

    private func enqueue(_ write: Write) {
        pendingRuns.append((write, "palette-usage:\(UUID().uuidString)"))
        guard recorder == nil else { return }
        sendPending()
    }

    /// Sends the waiting writes in order, off main, then rereads the history once (``sent()``). A write whose
    /// daemon went away is dropped (never written elsewhere).
    private func sendPending() {
        guard case .daemon(let client, _) = owner else {
            pendingRuns.removeAll()
            return
        }
        let batch = pendingRuns
        pendingRuns.removeAll()
        let mainWork = mainWork
        // task-owner: DaemonPaletteUsageStore.recorder (cancelled with the store); one batch of writes, off main (recipe R-hop)
        recorder = Task { @concurrent [weak self] in
            await Self.send(batch, to: client)
            guard !Task.isCancelled else { return }
            mainWork.postFromAnyThread(.visible, owner: "DaemonPaletteUsageStore.sent") { [weak self] in self?.sent() }
        }
    }

    /// Each write of `batch` in order; a failed one is logged and the next still goes.
    @concurrent private nonisolated static func send(_ batch: [(write: Write, idempotencyKey: String)],
                                                     to client: PaletteUsageStateClient) async {
        for run in batch where !Task.isCancelled {
            do {
                switch run.write {
                case .record(let key, let query):
                    _ = try await client.record(key: key, query: query, idempotencyKey: run.idempotencyKey)
                case .hide(let key, let hidden):
                    _ = try await client.hide(key: key, hidden: hidden, idempotencyKey: run.idempotencyKey)
                case .forget(let key):
                    _ = try await client.forget(key: key, idempotencyKey: run.idempotencyKey)
                }
            } catch {
                logger.error("palette usage record failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A batch's reply on main: the writes that came while it ran go next, else the history is read again.
    private func sent() {
        recorder = nil
        if pendingRuns.isEmpty { fetch() } else { sendPending() }
    }
}
