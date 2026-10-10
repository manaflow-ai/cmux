public import Foundation

/// UPDATE-CARD (Lawrence 2026-10-06; changelog 2026-10-10, cx-lntk): the
/// card above the sidebar footer while an update is staged: the short title
/// "Update Ready", the short version and build date, the first changelog
/// lines with a Release Notes link, the Automatic
/// Updates checkbox (`updates.downloadAutomatically`) and one Restart to
/// Update button; while the click installs, the button reads Installing…
/// and is disabled. Its hover popover is ``notes``. Pure and localized.
nonisolated public struct UpdateReadyCard: Equatable, Sendable {
    public var title: String
    /// "1.0.0 nightly 3801702 · Oct 10, 2026", nil when unknown.
    public var detail: String?
    /// The first changelog lines (at most ``UpdateChangelog/shownLines``).
    public var lines: [String]
    /// "Release Notes" and the full list it opens.
    public var releaseNotesTitle: String
    public var releaseNotesURL: URL?
    public var buttonTitle: String
    /// The click was taken: the button is disabled until the relaunch.
    public var isInstalling: Bool
    public var automaticUpdatesTitle: String
    /// The checkbox state: `updates.downloadAutomatically`.
    public var automaticUpdates: Bool
    public var notes: UpdateReadyNotes

    public init(version: String?, isInstalling: Bool, automaticUpdates: Bool, notes: UpdateReadyNotes,
                changelog: UpdateChangelog? = nil) {
        title = UpdaterStrings.readyToInstall
        detail = (changelog ?? version.map { UpdateChangelog(version: $0, date: nil, lines: []) })?.detail
        lines = changelog?.lines ?? []
        releaseNotesTitle = UpdaterStrings.releaseNotes
        releaseNotesURL = notes.moreURL
        buttonTitle = isInstalling ? UpdaterStrings.installing : UpdaterStrings.restartToUpdate
        self.isInstalling = isInstalling
        automaticUpdatesTitle = UpdaterStrings.automaticUpdates
        self.automaticUpdates = automaticUpdates
        self.notes = notes
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
