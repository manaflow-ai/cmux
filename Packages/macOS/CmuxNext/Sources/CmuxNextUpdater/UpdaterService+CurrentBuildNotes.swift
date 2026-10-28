import Foundation

/// The "cmux Updated!" card names what changed even when the update record
/// carries no change list (2026-10-20, Lawrence on "Updated to nightly
/// 3939068 / What's new in this build": "not descriptive enough at all").
/// A record saved before the staged notes loaded, a manual install or an
/// update from a build that saved no record all left the card with no items;
/// this build's own signed notes fill it instead, read once per launch.
extension UpdaterService {
    /// Reads this build's verified notes once, when the Updated card shows
    /// and its record has no changes to list. Called after ``WhatsNewCenter/load()``.
    @discardableResult
    public func loadCurrentBuildNotesIfNeeded() -> Task<Void, Never>? {
        guard currentBuildNotesTask == nil, currentBuildNotes == nil, !identity.build.isEmpty, whatsNew.isUpdated,
              (recordedHighlights?.items.isEmpty ?? true) else { return nil }
        let build = identity.build
        let load = notesLoader ?? { [releaseNotes] build in await releaseNotes?.notes(for: build) }
        let task = Task { [weak self] in
            let notes = await load(build)
            guard let self, !Task.isCancelled else { return }
            self.currentBuildNotes = notes
            self.log.append("current build notes: \(build) \(notes == nil ? "none" : "\(notes?.changeItems.count ?? 0) changes")")
        }
        currentBuildNotesTask = task
        return task
    }

    /// The record's own highlights: the ones the popover showed before the
    /// restart, else built from its changelog lines. Nil without a record.
    var recordedHighlights: UpdateHighlights? {
        guard let record = whatsNew.lastUpdate else { return nil }
        return record.highlights ?? UpdateHighlights(version: record.toVersion, build: record.toBuild,
                                                     fromVersion: record.fromVersion, fromBuild: record.fromBuild,
                                                     notes: nil, appcast: record.changelog)
    }
}
