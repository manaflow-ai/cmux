import Foundation

/// What's New after an update (cx-ncc.45, decision D1): the staged update
/// is recorded for the next build (``WhatsNewLastUpdate``) when it stages,
/// off the main thread, and again at the click only when its changelog
/// changed since (its signed notes load after staging), so the click does
/// no file work in the usual case.
extension UpdaterService {
    /// The update staged: record it for the build it installs.
    func recordStagedUpdate() {
        guard let lastUpdates, let build = stagedBuild(), let record = updateRecord(toBuild: build),
              record.changelog != recordedUpdate?.changelog || build != recordedUpdate?.toBuild else { return }
        recordedUpdate = record
        // task-owner: one small file write that ends by itself; a newer record replaces it.
        Task.detached { lastUpdates.write(record) }
    }

    /// The click installs: rewrite the record only when the changelog
    /// changed after staging. Synchronous: the process ends soon after.
    func recordBeforeInstall() {
        guard let lastUpdates, let recorded = recordedUpdate, let record = updateRecord(toBuild: recorded.toBuild),
              record.changelog != recorded.changelog else { return }
        recordedUpdate = record
        // concurrency-allow: at most one ~1 KB atomic write per update, at the click, only when the notes changed after staging.
        lastUpdates.write(record)
    }

    private func updateRecord(toBuild: String) -> WhatsNewLastUpdate? {
        // No changelog lines still records the update: the card then says
        // only which version it updated to.
        let changelog = stagedChangelog ?? UpdateChangelog(version: stagedVersion ?? toBuild, date: nil, lines: [])
        return WhatsNewLastUpdate(fromVersion: identity.shortVersion, fromBuild: identity.build,
                                  toVersion: stagedVersion ?? changelog.version ?? toBuild, toBuild: toBuild,
                                  stagedAt: now(), changelog: changelog)
    }
}
