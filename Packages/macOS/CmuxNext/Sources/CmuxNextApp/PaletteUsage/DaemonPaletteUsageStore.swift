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

    private unowned let services: AppServices
    private let local: LocalPaletteUsageStore
    private let preferences: URL
    /// The connection whose former histories were imported this launch.
    private var importedOn: ObjectIdentifier?
    /// The revision of the mirror; an older snapshot never replaces it.
    private var revision: UInt64 = 0
    private var fetching: Task<Void, Never>?
    private var fetchAgain = false
    private(set) var history: FrecencyStore
    var onChange: (@MainActor () -> Void)?

    init(services: AppServices, local: LocalPaletteUsageStore = LocalPaletteUsageStore(persistence: UserDefaultsFrecencyPersistence()),
         preferences: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")) {
        self.services = services
        self.local = local
        self.preferences = preferences
        history = local.history
    }

    private var daemon: DaemonService { services.machines.local }

    private enum Owner {
        case daemon(PaletteUsageStateClient, ObjectIdentifier)
        /// Connected to a daemon without `palette-usage-v1`.
        case local
        case away
    }

    private var owner: Owner {
        guard let connection = daemon.connection else { return .away }
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
                let legacy = await Task.detached { [preferences] in PaletteUsageWire.legacyHistories(preferences: preferences) }.value
                var importedAny = false
                for (source, former) in legacy where !snapshot.imported.contains(source) {
                    do {
                        _ = try await client.importHistory(source: source, entries: PaletteUsageWire.importRows(former),
                                                           idempotencyKey: "palette-usage-import:\(source)")
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
        case .daemon(let client, _):
            let idempotencyKey = "palette-usage:\(UUID().uuidString)"
            Task { [weak self] in
                do {
                    _ = try await client.record(key: key, query: query, idempotencyKey: idempotencyKey)
                    self?.fetch()
                } catch {
                    Self.logger.error("palette usage record failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
