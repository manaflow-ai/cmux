import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// Debug Settings "Simulate pending update" (`sidebar.updateCard.simulatePending`, DEV and
/// NIGHTLY; Leo 2026-10-20: make the update card visibly verifiable): the Update Ready card and
/// its changelog preview for a pretend staged update, with real published notes. Nothing
/// downloads or installs (`UpdaterService.debugStage`, as `debug.updater {action: "stage"}`).
/// The notes are the newest published nightly's that has highlights, else this build's own,
/// else the sample notes when offline with nothing cached.
extension DebugUpdater {
    /// The build whose notes the simulation shows: the newest published build with highlights,
    /// else the newest one at all; nil for an empty index (offline with nothing cached).
    static func simulatedBuild(from index: [ReleaseNotesIndexEntry]) -> String? {
        let newest = index.sorted { ($0.date, $0.build) > ($1.date, $1.build) }
        return (newest.first { $0.highlights > 0 } ?? newest.first)?.build
    }

    /// Stages the pretend update. Returns the version shown and whether the notes are real.
    @discardableResult
    static func stageSimulated(_ updater: UpdaterService) async -> (version: String, real: Bool) {
        let store = updater.changelogNotes ?? updater.releaseNotes
        var notes: ReleaseNotes?
        if let store {
            if let build = simulatedBuild(from: await store.index()) { notes = await store.notes(for: build) }
            if notes == nil, !updater.identity.build.isEmpty { notes = await store.notes(for: updater.identity.build) }
        }
        let version = notes?.shortVersion ?? "1.99.0"
        updater.debugStage(version: version, notes: notes ?? .debugFake(version: version, changes: 12))
        return (version, notes != nil)
    }
}

extension AppServices {
    /// Follows the Debug Settings switch: on stages the pretend update, off follows the real
    /// updater again. An observation, not a poll; a build without Debug Settings never turns it on.
    func observeSimulatedUpdate() {
        simulatedUpdateObservation?.cancel()
        simulatedUpdateObservation = Task { [weak self] in
            var last = false
            for await on in ObservationStream({ SidebarTunables.simulatePendingUpdate.value }) where on != last {
                last = on
                guard let updater = self?.updater else { return }
                if on {
                    await DebugUpdater.stageSimulated(updater)
                } else {
                    updater.debugStage(version: nil, notes: nil)
                }
            }
        }
    }
}
