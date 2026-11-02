public import Foundation

/// UPDATE-CARD (Lawrence 2026-10-06; Leo 2026-10-13): the card above the sidebar footer while an
/// update is staged says only what a glance needs: "Update Ready", the short version and build
/// date ("nightly 3845050 · Oct 13"), the Automatic Updates checkbox
/// (`updates.downloadAutomatically`) and one Restart to Update button; while the click installs,
/// the button reads Installing… and is disabled. Its hover popover adds what the card lacks: the
/// full build, the changelog highlights and "See all changes", once (the card keeps "See all
/// changes" only as an accessibility action). Pure and localized.
nonisolated public struct UpdateReadyCard: Equatable, Sendable {
    public var title: String
    /// "nightly 3845050 · Oct 13" (``UpdateChangelog/cardDetail``), nil when unknown.
    public var detail: String?
    /// "See all changes", the What's New page for the staged update
    /// (`UpdaterService.openStagedChangelog()`): the popup's link, and the card's
    /// accessibility action (the popup opens on hover only).
    public var seeAllTitle: String
    public var buttonTitle: String
    /// The click was taken: the button is disabled until the relaunch.
    public var isInstalling: Bool
    public var automaticUpdatesTitle: String
    /// The checkbox state: `updates.downloadAutomatically`.
    public var automaticUpdates: Bool
    public var notes: UpdateReadyNotes

    /// Why the last install of this build left the old one running, when it did
    /// (``UpdateInstallCheck``): the card says so instead of offering Restart to Update again.
    public var failure: UpdateInstallFailure?

    public init(version: String?, isInstalling: Bool, automaticUpdates: Bool, notes: UpdateReadyNotes,
                changelog: UpdateChangelog? = nil, failure: UpdateInstallFailure? = nil) {
        // While the click installs, the card says so in its title too, not only on its disabled button.
        title = isInstalling ? UpdaterStrings.installingUpdate : UpdaterStrings.readyToInstall
        detail = (changelog ?? version.map { UpdateChangelog(version: $0, date: nil, lines: []) })?.cardDetail
        seeAllTitle = UpdaterStrings.seeAllChanges
        buttonTitle = isInstalling ? UpdaterStrings.installing : UpdaterStrings.restartToUpdate
        self.isInstalling = isInstalling
        automaticUpdatesTitle = UpdaterStrings.automaticUpdates
        self.automaticUpdates = automaticUpdates
        self.notes = notes
        // The install of this build failed: the title says it did not install, the detail line
        // says why, and the popover (and the button's help) has the full reason and what to do.
        self.failure = isInstalling ? nil : failure
        if let failure = self.failure {
            title = UpdaterStrings.installFailedTitle
            detail = failure.summary
            buttonTitle = UpdaterStrings.tryAgain
            self.notes.headline = failure.message
        }
    }
}

/// The update card's hover popover: what a click does, that sessions keep
/// running, the newest changes from the staged build's release notes and a
/// link to the rest. Built from notes fetched when the update was staged,
/// so showing it never touches the network.
nonisolated public struct UpdateReadyNotes: Equatable, Sendable {
    /// Changes the popover lists before "N more changes".
    public static let shownChanges = 5

    public var headline: String
    public var keepsRunning: String
    /// "What's changed", or nil when the notes list no change.
    public var whatsChangedTitle: String?
    /// The newest changes first, at most ``shownChanges``.
    public var changes: [ReleaseNotes.ChangeItem]
    /// Changes not listed.
    public var moreCount: Int
    /// "N more changes" (or "Release Notes" without notes), nil without a link.
    public var moreTitle: String?
    /// The full release notes.
    public var moreURL: URL?

    public init(version: String?, notes: ReleaseNotes?, fullNotesURL: URL?, limit: Int = UpdateReadyNotes.shownChanges) {
        headline = version.map(UpdaterStrings.downloadedHeadline) ?? UpdaterStrings.downloadedHeadlineNoVersion
        keepsRunning = UpdaterStrings.keepsRunning
        let all = notes?.changeItems ?? []
        changes = Array(all.prefix(max(0, limit)))
        whatsChangedTitle = changes.isEmpty ? nil : UpdaterStrings.whatsChanged
        moreCount = all.count - changes.count
        moreURL = fullNotesURL
        if fullNotesURL == nil {
            moreTitle = nil
        } else if moreCount > 0 {
            moreTitle = UpdaterStrings.moreChanges(moreCount)
        } else {
            moreTitle = notes == nil ? UpdaterStrings.releaseNotes : nil
        }
    }
}
