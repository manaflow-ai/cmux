import CmuxNextDaemon
import CmuxNextPalette
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
@MainActor
final class DaemonPaletteUsageStore: PaletteUsageStore {
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.usage")

    private weak var services: AppServices?
    private let local: LocalPaletteUsageStore
    private let preferences: URL
    /// The connection whose former histories were imported this launch.
    private var importedOn: ObjectIdentifier?
    /// The revision of the mirror; an older snapshot never replaces it.
    private var revision: UInt64 = 0
    private var fetching: Task<Void, Never>?
    private var fetchAgain = false
    /// Runs waiting to be recorded, oldest first, and the one task that
    /// records them in order (cancelled with the store).
    private var pendingRuns: [(key: String, query: String, idempotencyKey: String)] = []
    private var recorder: Task<Void, Never>?
    private(set) var history: FrecencyStore
    var onChange: (@MainActor () -> Void)?

    init(services: AppServices, local: LocalPaletteUsageStore = LocalPaletteUsageStore(persistence: UserDefaultsFrecencyPersistence()),
         preferences: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")) {
        self.services = services
        self.local = local
        self.preferences = preferences
        history = local.history
    }

    isolated deinit {
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
        guard daemon.supports(DaemonCapabilities.shared.paletteUsage) else { return .local }
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
        fetching = Task { [weak self] in
            await self?.fetchOnce()
            guard let self else { return }
            fetching = nil
            if fetchAgain {
                fetchAgain = false
                fetch()
            }
        }
    }

    private func fetchOnce() async {
        guard case .daemon(let client, let id) = owner else { return }
        do {
            var snapshot = try PaletteUsageWire.history(try await client.get())
            if importedOn != id {
                var importedAny = false
                for former in await PaletteUsageLegacyHistory.read(preferences: preferences)
                where !snapshot.imported.contains(former.source) && !Task.isCancelled {
                    do {
                        _ = try await client.importHistory(source: former.source, entries: former.rows,
                                                           idempotencyKey: "palette-usage-import:\(former.source)")
                        importedAny = true
                    } catch {
                        Self.logger.error("palette usage import of one former history failed: \(String(describing: error), privacy: .public)")
                    }
                }
                importedOn = id
                if importedAny { snapshot = try PaletteUsageWire.history(try await client.get()) }
            }
            guard snapshot.revision >= revision else { return }
            revision = snapshot.revision
            history = snapshot.history
            onChange?()
        } catch {
            Self.logger.error("palette usage fetch failed: \(String(describing: error), privacy: .public)")
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
            pendingRuns.append((key, query, "palette-usage:\(UUID().uuidString)"))
            guard recorder == nil else { return }
            recorder = Task { [weak self] in
                await self?.recordPending()
                self?.recorder = nil
            }
        }
    }

    /// Records the waiting runs in order, then rereads the history once. A
    /// run whose daemon went away is dropped (never written elsewhere).
    private func recordPending() async {
        while !pendingRuns.isEmpty, !Task.isCancelled {
            let run = pendingRuns.removeFirst()
            guard case .daemon(let client, _) = owner else {
                pendingRuns.removeAll()
                return
            }
            do {
                _ = try await client.record(key: run.key, query: run.query, idempotencyKey: run.idempotencyKey)
            } catch {
                Self.logger.error("palette usage record failed: \(String(describing: error), privacy: .public)")
            }
        }
        if !Task.isCancelled { fetch() }
    }
}
