import CmuxNextCompat
import CmuxUpdater
public import Foundation

/// Per-PR kill switches (leo-workspace briefs/2026-10-20-gui-push/partial-rollback.md, section 2):
/// reads the signed `notes/flags.json` beside the updater's feed and applies the list it turns off
/// for the updater's ring (`updates.channel`) to ``KillSwitches``. A missing, unsigned or mis-signed
/// document turns nothing off, so every change ships.
///
/// ``follow()`` reads at once, then whenever the ring moves or a check leaves the checking phase:
/// one observation of the updater (no timer, no poll). The updater owns its reader
/// (`UpdaterService.killSwitchReader`) and stops the one before when it starts another; ``stop()``
/// cancels its observation, which also ends at its next wake after the reader or the updater is
/// gone. One read runs at a time, so fetches and cache writes never overlap: a read asked while one
/// runs is done once after it (that one may have fetched before a check published a newer document,
/// or for a ring that moved), and a read whose ring moved meanwhile applies nothing.
@MainActor
public final class KillSwitchReader {
    private weak var updater: UpdaterService?
    private let switches: KillSwitches
    private let store: @MainActor (UpdaterService) -> ReleaseNotesStore?
    private var observation: Task<Void, Never>?
    private var reading: (cohort: String, task: Task<Void, Never>)?
    /// Invalidate every earlier read when a later ring/read request is observed, including a move
    /// back to a cohort whose name matches the earlier request.
    private var generation = 0
    private var stopped = false
    /// A read was asked while ``reading`` ran: one more runs after it.
    private var readsAgain = false

    /// The app's reader: the updater's own notes store, the shared switches.
    public convenience init(updater: UpdaterService) {
        self.init(updater: updater, switches: .shared) { $0.releaseNotes }
    }

    init(updater: UpdaterService, switches: KillSwitches,
         store: @escaping @MainActor (UpdaterService) -> ReleaseNotesStore?) {
        self.updater = updater
        self.switches = switches
        self.store = store
    }

    nonisolated deinit {
        observation?.cancel()
    }

    /// Follows the updater while it lives (see the type's note).
    public func follow() {
        stopped = false
        observation?.cancel()
        let changes = ObservationStream({ [weak updater] in (updater?.ring, updater?.flow.phase == .checking) })
        observation = Task { [weak self] in
            var lastRing: UpdateRing?
            var wasChecking = false
            for await (ring, checking) in changes {
                guard let self, let ring, !Task.isCancelled else { return }
                if ring != lastRing || (wasChecking && !checking) { read() }
                lastRing = ring
                wasChecking = checking
            }
        }
    }

    /// Ends ``follow()``'s observation; the switches keep their last verified list.
    public func stop() {
        stopped = true
        generation &+= 1
        observation?.cancel()
        observation = nil
        reading?.task.cancel()
        reading = nil
        readsAgain = false
    }

    /// Reads the document once and replaces the turned-off switches: a verified document's list for
    /// the updater's ring, else none. While a read runs, the task returned ends after the one read
    /// that follows it. Nil when the updater is gone.
    @discardableResult
    func read() -> Task<Void, Never>? {
        guard !stopped, let updater else { return nil }
        generation &+= 1
        let requestedGeneration = generation
        let cohort = updater.ring.rawValue
        if let reading {
            readsAgain = true
            let current = reading.task
            return Task { [weak self] in
                await current.value
                // The read in flight started the next one before it ended.
                await self?.reading?.task.value
            }
        }
        let store = store(updater)
        let switches = switches
        let task = Task { [weak self] in
            let off = await store?.flags()?.off(cohort: cohort) ?? []
            guard let self, !Task.isCancelled, !self.stopped else { return }
            reading = nil
            if self.generation == requestedGeneration, self.updater?.ring.rawValue == cohort,
               off != switches.off {
                switches.replace(off: off)
                self.updater?.log.append("kill switches off: \(off.isEmpty ? "none" : off.sorted().joined(separator: ", "))")
            }
            if readsAgain {
                readsAgain = false
                read()
            }
        }
        reading = (cohort, task)
        return task
    }
}
