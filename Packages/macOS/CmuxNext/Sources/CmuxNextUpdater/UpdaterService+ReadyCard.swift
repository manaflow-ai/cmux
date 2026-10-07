import CmuxUpdater
public import Foundation

/// UPDATE-CARD: the staged update card's content, its release notes
/// (fetched once when the update is staged, never on hover) and its
/// Automatic Updates checkbox (`updates.downloadAutomatically`, written by
/// the App's settings path).
extension UpdaterService {
    /// The card while an update is staged or installing; nil otherwise and,
    /// for a staged update, under `updates.notify` silent (``footerPill``).
    public var readyCard: UpdateReadyCard? {
        guard let pill = footerPill else { return nil }
        let notes = UpdateReadyNotes(version: stagedVersion, notes: stagedNotes, fullNotesURL: stagedReleaseNotesURL)
        return UpdateReadyCard(version: stagedVersion, isInstalling: !pill.isEnabled, automaticUpdates: automaticUpdates, notes: notes)
    }

    /// The full release notes of the staged update: the build's GitHub
    /// release or commit, else the releases page.
    public var stagedReleaseNotesURL: URL? {
        stagedVersion.flatMap { UpdateState.ReleaseNotes(displayVersionString: $0)?.url }
            ?? URL(string: "https://github.com/manaflow-ai/cmux/releases")
    }

    /// The checkbox: writes the setting; the setting's change comes back
    /// through ``configure(checkAutomatically:checkInterval:downloadAutomatically:metered:)``.
    public func setAutomaticUpdates(_ on: Bool) {
        writeAutomaticUpdates?(on)
    }

    /// Follows the flow's phase: a staged update records its version and
    /// loads its notes once; installing keeps both; anything else clears.
    func followStagedUpdate(_ phase: UpdateIndicatorPhase) {
        switch phase {
        case .ready(let version):
            if let version, stagedVersion != version { stagedVersion = version }
            loadStagedNotes()
        case .installing:
            break
        case .hidden, .checking, .downloading, .available, .note:
            stagedNotesTask?.task.cancel()
            stagedNotesTask = nil
            if stagedVersion != nil { stagedVersion = nil }
            if stagedNotes != nil { stagedNotes = nil }
        }
    }

    /// Reads the staged build's verified notes (once per build).
    private func loadStagedNotes() {
        guard let build = stagedBuild(), stagedNotesTask?.build != build else { return }
        stagedNotesTask?.task.cancel()
        let load = notesLoader ?? { [releaseNotes] build in await releaseNotes?.notes(for: build) }
        let task = Task { [weak self] in
            let notes = await load(build)
            guard let self, !Task.isCancelled, self.stagedNotesTask?.build == build else { return }
            self.stagedNotes = notes
            self.log.append("staged notes: \(build) \(notes == nil ? "none" : "\(notes?.changeItems.count ?? 0) changes")")
        }
        stagedNotesTask = (build, task)
    }

    /// DEV/NIGHTLY screenshots (`debug.updater {action: "stage"}`): shows a
    /// staged `version` with `notes`, no download; nil clears it.
    public func debugStage(version: String?, notes: ReleaseNotes?) {
        guard let version else {
            debugIndicatorPhase = nil
            return
        }
        debugIndicatorPhase = .ready(version: version)
        stagedNotes = notes
    }
}
