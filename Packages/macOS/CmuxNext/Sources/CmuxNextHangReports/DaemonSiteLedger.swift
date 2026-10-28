public import CmuxNextCompat
public import Foundation

/// The daemon sites this install already reported, per daemon life (``DaemonDiagnosticSite/Sighting``). The
/// headless daemon outlives app launches and replays every site of its life to each launch's connection; the
/// ledger, saved across launches, lets each pair through once, so a relaunch adds no sample and no event
/// ("one event per daemon life"). A new daemon life starts a new entry.
///
/// A pure value: `BlockingReportSink` holds one, loads it at the first daemon site and saves it after each
/// admitted one.
///
/// ```swift
/// var ledger = store.load()
/// if ledger.admit(sighting) { store.save(ledger); report(sighting.site) }
/// ```
public nonisolated struct DaemonSiteLedger: Codable, Sendable, Equatable {
    /// The most daemon lives remembered: the current one and a few before it (oldest dropped first).
    public static let maxLives = 4
    /// The most sites remembered per life: a daemon sends at most 512.
    public static let maxSitesPerLife = 1_024

    /// One daemon life's reported sites (``DaemonDiagnosticSite/key``).
    public struct Life: Codable, Sendable, Equatable {
        /// ``DaemonDiagnosticSite/Sighting/life(pid:generation:)``.
        public var life: String
        /// The keys of the sites reported for it.
        public var sites: Set<String>
    }

    /// The remembered lives, oldest first.
    public private(set) var lives: [Life] = []

    /// Makes an empty ledger.
    public init() {}

    /// Whether `sighting` is new; when it is, records it. A life past ``maxSitesPerLife`` admits nothing more.
    public mutating func admit(_ sighting: DaemonDiagnosticSite.Sighting) -> Bool {
        let key = sighting.site.key
        guard let index = lives.firstIndex(where: { $0.life == sighting.daemonLife }) else {
            lives.append(Life(life: sighting.daemonLife, sites: [key]))
            if lives.count > Self.maxLives { lives.removeFirst(lives.count - Self.maxLives) }
            return true
        }
        guard !lives[index].sites.contains(key), lives[index].sites.count < Self.maxSitesPerLife else { return false }
        lives[index].sites.insert(key)
        return true
    }

    /// Where the ledger persists.
    public struct Store: Sendable {
        /// Reads the saved ledger (once, at the first daemon site); an empty one when none was saved.
        public var load: @Sendable () -> DaemonSiteLedger
        /// Saves the ledger after each admitted site.
        public var save: @Sendable (DaemonSiteLedger) -> Void

        /// Makes the value from its parts.
        public init(load: @escaping @Sendable () -> DaemonSiteLedger, save: @escaping @Sendable (DaemonSiteLedger) -> Void) {
            self.load = load
            self.save = save
        }

        /// The defaults key of ``standardDefaults``.
        public static let defaultsKey = "cmux.next.blockingReports.daemonSites"

        /// The ledger as JSON under ``defaultsKey`` in the standard defaults (thread-safe); an unreadable one
        /// reads as empty.
        public static let standardDefaults = Store(
            load: {
                UserDefaults.standard.data(forKey: Store.defaultsKey)
                    .flatMap { try? JSONDecoder().decode(DaemonSiteLedger.self, from: $0) } ?? DaemonSiteLedger()
            },
            save: { ledger in
                guard let data = try? JSONEncoder().encode(ledger) else { return }
                UserDefaults.standard.set(data, forKey: Store.defaultsKey)
            })
    }
}
