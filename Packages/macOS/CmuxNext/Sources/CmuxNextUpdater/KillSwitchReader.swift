import CmuxNextCompat
import CmuxUpdater
public import Foundation

/// Per-PR kill switches (leo-workspace briefs/2026-10-20-gui-push/partial-rollback.md, section 2):
/// reads the signed `notes/flags.json` beside the updater's feed and applies the list it turns off
/// for the updater's ring (`updates.channel`) to ``KillSwitches``. A missing, unsigned or mis-signed
/// document turns nothing off, so every change ships.
///
/// ``follow()`` reads at once, then whenever the ring moves or a check leaves the checking phase:
/// one observation of the updater (no timer, no poll). The app's reader is owned by ``app``
/// (``start(updater:)``); ``stop()``, or starting a new one, cancels its observation, which also
/// ends at its next wake after the reader or the updater is gone. A read already in flight for the
/// same ring is joined; a newer read wins over an older one.
@MainActor
public final class KillSwitchReader {
    private weak var updater: UpdaterService?
    private let switches: KillSwitches
    private let store: @MainActor (UpdaterService) -> ReleaseNotesStore?
    private var observation: Task<Void, Never>?
    private var reading: (cohort: String, task: Task<Void, Never>)?
    /// Counts reads: only the newest one applies its list or clears ``reading``.
    private var generation = 0

    /// The app's reader, set by ``start(updater:)``.
    public private(set) static var app: KillSwitchReader?

    /// Makes the app's reader for `updater` and follows it; a reader started before stops.
    public static func start(updater: UpdaterService) {
        app?.stop()
        let reader = KillSwitchReader(updater: updater)
        app = reader
        reader.follow()
    }

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

    /// Follows the updater while it lives (see the type's note).
    public func follow() {
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
        observation?.cancel()
        observation = nil
    }

    /// Reads the document once and replaces the turned-off switches: a verified document's list for
    /// the updater's ring, else none. Nil when the updater is gone.
    @discardableResult
    func read() -> Task<Void, Never>? {
        guard let updater else { return nil }
        let cohort = updater.ring.rawValue
        if let reading, reading.cohort == cohort { return reading.task }
        generation += 1
        let mine = generation
        let store = store(updater)
        let switches = switches
        let task = Task { [weak self] in
            let off = await store?.flags()?.off(cohort: cohort) ?? []
            // A newer read (the ring moved meanwhile, even back again) owns the result.
            guard let self, generation == mine else { return }
            reading = nil
            guard off != switches.off else { return }
            switches.replace(off: off)
            self.updater?.log.append("kill switches off: \(off.isEmpty ? "none" : off.sorted().joined(separator: ", "))")
        }
        reading = (cohort, task)
        return task
    }
}
