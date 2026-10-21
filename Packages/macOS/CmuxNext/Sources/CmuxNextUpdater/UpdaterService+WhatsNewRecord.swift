import CmuxUpdater
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
              record.changelog != recordedUpdate?.changelog || record.highlights != recordedUpdate?.highlights
                || build != recordedUpdate?.toBuild else { return }
        recordedUpdate = record
        writeRecord(record, to: lastUpdates)
    }

    /// The click installs: the record says the install started (a launch of this build after
    /// it means the install did not take), with the changelog as it is now. Synchronous: the
    /// process ends soon after.
    func recordBeforeInstall() {
        guard let lastUpdates, let recorded = recordedUpdate else { return }
        var record = recorded
        if let fresh = updateRecord(toBuild: recorded.toBuild), fresh.changelog != recorded.changelog || fresh.highlights != recorded.highlights {
            record = fresh
        }
        record.installStartedAt = now()
        record.installFailure = nil
        recordedUpdate = record
        // concurrency-allow: one ~1 KB atomic write per install, at the click, before the app quits for the installer.
        lastUpdates.write(record)
    }

    /// A quit installs the staged update (`updates.installOnQuit`): the record says the install started.
    func recordInstallStarted() {
        guard let lastUpdates, var record = recordedUpdate, record.installStartedAt == nil else { return }
        record.installStartedAt = now()
        recordedUpdate = record
        // concurrency-allow: one ~1 KB atomic write at the quit that installs; the process ends right after.
        lastUpdates.write(record)
    }

    /// The install ended without a relaunch: the record keeps why (Sparkle's error, the install
    /// watchdog's), which the next launch of this build shows if the person quits first.
    func recordInstallFailure() {
        guard let lastUpdates, var record = recordedUpdate, record.installStartedAt != nil else { return }
        if case .error(let failure)? = controller?.model.effectiveState {
            record.installFailure = (failure.error as NSError).localizedDescription
        }
        recordedUpdate = record
        writeRecord(record, to: lastUpdates)
    }

    /// Writes off the main actor, after the write before it, so an older record never lands last.
    private func writeRecord(_ record: WhatsNewLastUpdate, to store: WhatsNewLastUpdateStore) {
        let previous = recordWrite
        // task-owner: one small file write that ends by itself; the next write and the install click wait for it.
        recordWrite = Task.detached {
            await previous?.value
            store.write(record)
        }
    }

    private func updateRecord(toBuild: String) -> WhatsNewLastUpdate? {
        // No changelog lines still records the update: the card then says
        // only which version it updated to.
        let changelog = stagedChangelog ?? UpdateChangelog(version: stagedVersion ?? toBuild, date: nil, lines: [])
        return WhatsNewLastUpdate(fromVersion: identity.shortVersion, fromBuild: identity.build,
                                  toVersion: stagedVersion ?? changelog.version ?? toBuild, toBuild: toBuild,
                                  stagedAt: now(), changelog: changelog, highlights: stagedHighlights)
    }
}

extension UpdaterService {
    /// "See What's New" on the "cmux Updated!" card (the React card,
    /// cx-urd.61.2): the changelog page for the span this update crossed,
    /// and the update counts as seen (the card goes; only the card's x,
    /// ``WhatsNewCenter/dismissUpdated()``, clears ``WhatsNewCenter/lastUpdate``).
    @discardableResult
    public func openWhatsNewForLastUpdate() -> Bool {
        let span = whatsNew.lastUpdate.map { ($0.fromVersion, $0.toVersion) }
        whatsNew.markUpdateSeen()
        if let span, let open = openChangelogSpan { return open(span.0, span.1) }
        return openChangelog?() ?? false
    }
}
