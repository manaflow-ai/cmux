import CmuxNextWakeups
package import Foundation

/// Owns this build's ``ErrorJournal`` and the places it harvests: the app's own unified log
/// (page console errors included), the Chief's acpmux `daemon.log`, `host.log` and
/// `client.log`, the app's own acpmux log, and cmux crash reports. Harvests every
/// ``harvestInterval`` and before every `errors.list`.
///
/// The journal lives in `~/Library/Application Support/<bundle id>/errors`, one per build.
/// The app builds its sources (`ErrorJournalService.make(environment:)` in CmuxNextApp).
@MainActor
package final class ErrorJournalService {
    package let journal: ErrorJournal
    package let sources: [any ErrorHarvestSource]
    /// The harvest that runs now, if any.
    private var harvesting: Task<Void, Never>?
    /// The next harvest, ``harvestInterval`` after the last one ended.
    private let nextHarvest = DemandTimer(owner: "error-journal.harvest")
    private var running = false
    /// Bumped by start() and stop(): a harvest or deadline of an earlier run does nothing.
    private var generation: UInt64 = 0

    /// How often the journal reads its sources while the app runs.
    package static let harvestInterval: Duration = .seconds(300)

    package init(journal: ErrorJournal, sources: [any ErrorHarvestSource]) {
        self.journal = journal
        self.sources = sources
    }

    /// The journal folder of a build.
    package static func directory(bundleID: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("errors", isDirectory: true)
    }

    /// Starts the periodic harvest; the first one runs at once.
    package func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        harvest(generation)
    }

    /// Stops harvesting and writes what is pending.
    package func stop() async {
        running = false
        generation &+= 1
        nextHarvest.cancel()
        harvesting?.cancel()
        harvesting = nil
        await journal.flush()
    }

    /// Runs one harvest off the main actor; when it ends, the next one is due after ``harvestInterval``.
    private func harvest(_ run: UInt64) {
        guard running, run == generation else { return }
        let journal = journal
        let sources = sources
        harvesting = Task.detached(priority: .utility) { [weak self] in
            await journal.harvest(sources)
            guard !Task.isCancelled else { return }
            await self?.harvestEnded(run)
        }
    }

    private func harvestEnded(_ run: UInt64) {
        guard running, run == generation else { return }
        harvesting = nil
        nextHarvest.schedule(after: Self.harvestInterval) { [weak self] in
            await self?.harvest(run)
        }
    }
}
