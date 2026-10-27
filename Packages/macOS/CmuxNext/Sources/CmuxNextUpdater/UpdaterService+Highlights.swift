import CmuxUpdater
import Foundation

/// The staged update's highlights (cx-ncc.45.5): what the "Update ready"
/// popover and card show before the restart, and the span "See all changes"
/// opens. Data and flow only; the whats-new-design lane draws them.
extension UpdaterService {
    /// The staged update's top changes, or nil while nothing is staged.
    /// Recomputed from the staged notes (fetched and verified at staging)
    /// and the staged appcast item, so it is offline-safe once downloaded.
    public var stagedHighlights: UpdateHighlights? {
        guard let version = stagedVersion ?? stagedNotes?.shortVersion else { return nil }
        let build = stagedBuild() ?? stagedNotes?.build ?? version
        return UpdateHighlights(version: version, build: build, fromVersion: identity.shortVersion, fromBuild: identity.build,
                                notes: stagedNotes, appcast: stagedChangelog)
    }

    /// The highlights of the update this launch completed, for the "cmux
    /// Updated!" card: the ones the popover showed before the restart, else
    /// built from the recorded changelog lines; the span runs from the
    /// previous version to this one. Nil when no update is recorded.
    public var lastUpdateHighlights: UpdateHighlights? {
        guard let record = whatsNew.lastUpdate, var highlights = recordedHighlights else { return nil }
        // A record with no change list (saved before the staged notes loaded): this build's own notes.
        if highlights.items.isEmpty, let notes = currentBuildNotes {
            highlights = UpdateHighlights(version: record.toVersion, build: record.toBuild, fromVersion: record.fromVersion,
                                          fromBuild: record.fromBuild, notes: notes, appcast: record.changelog)
        }
        highlights.changelog = UpdateHighlights.Changelog(from: record.fromVersion, to: record.toVersion)
        // A record saved before `builtAt`: the staged appcast item's date.
        if highlights.builtAt == nil { highlights.builtAt = record.changelog.date.flatMap(UpdateHighlights.instant) }
        highlights.pulled = pulledWatch.pulledBuilds
        return highlights
    }

    /// The "cmux Updated!" card without a saved record (a manual or brew
    /// install, an update from a build that saved none): this version, the
    /// span from the last version seen, and this build's own notes once read
    /// (``currentBuildNotes``). Nil when not updated.
    public var updatedWithoutRecordHighlights: UpdateHighlights? {
        guard whatsNew.lastUpdate == nil, whatsNew.isUpdated else { return nil }
        let from = whatsNew.lastSeen?.description ?? identity.shortVersion
        var highlights = UpdateHighlights(version: identity.shortVersion, build: identity.build, fromVersion: from, fromBuild: "",
                                          notes: currentBuildNotes, appcast: nil)
        highlights.pulled = pulledWatch.pulledBuilds
        return highlights
    }

    /// "See all changes": the changelog page for the releases after this
    /// build up to the staged one. Without signed notes for the staged build
    /// (a feed that publishes none) the page would be empty: the appcast's
    /// web release notes open instead, when it names them.
    @discardableResult
    public func openStagedChangelog() -> Bool {
        if stagedNotes == nil, let url = stagedReleaseNotesURL, let open = openReleaseNotesURL { return open(url) }
        guard let span = stagedHighlights?.changelog else { return openChangelog?() ?? false }
        if let open = openChangelogSpan { return open(span.from, span.to) }
        return openChangelog?() ?? false
    }
}
