public import CmuxNextWakeups
public import Foundation

/// What a job reads as on screen. Known kinds have text in the app's language
/// (Resources/LongJobs.xcstrings); any other kind shows the daemon's own (English) `title`.
nonisolated extension LongJob {
    /// The job's title in the app's language, else the daemon's `title`.
    public var displayTitle: String {
        switch kind {
        case Self.outputCleanupKind: Self.text("longJobs.kind.outputCleanup", "Cleaning up stored terminal output")
        case Self.outputCleanupStageKind: Self.text("longJobs.kind.outputCleanupStage", "Preparing the stored output cleanup")
        case Self.outputCleanupRemoveBackupKind: Self.text("longJobs.kind.outputCleanupRemoveBackup", "Removing old stored terminal output")
        case Self.registryOpenKind: Self.text("longJobs.kind.registryOpen", "Opening your saved sessions")
        case Self.adoptHostsKind: Self.text("longJobs.kind.adoptHosts", "Reconnecting your terminals")
        case Self.journalMaintenanceKind: Self.text("longJobs.kind.journalMaintenance", "Tidying the session journal")
        case Self.ledgerRetentionKind: Self.text("longJobs.kind.ledgerRetention", "Trimming old session history")
        case Self.ledgerCheckKind: Self.text("longJobs.kind.ledgerCheck", "Checking session history")
        case Self.historyCheckKind: Self.text("longJobs.kind.historyCheck", "Checking terminal history")
        case Self.compactKind: Self.text("longJobs.kind.compact", "Compacting stored sessions")
        case Self.updateDownloadKind: Self.text("longJobs.kind.updateDownload", "Downloading the cmux update")
        case Self.updateInstallKind: Self.text("longJobs.kind.updateInstall", "Installing the cmux update")
        case Self.browserImportKind: Self.text("longJobs.kind.browserImport", "Importing browser data")
        case Self.cloudUploadKind: Self.text("longJobs.kind.cloudUpload", "Uploading files to a Cloud machine")
        default: title.isEmpty ? kind : title
        }
    }

    /// "43%" in the app's locale, or nil while the job's size is unknown.
    public var percentText: String? {
        percent.map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    /// The line under the title: the daemon's detail (English from its catalog), else nothing.
    public var detailText: String? {
        guard let detail, !detail.isEmpty else { return nil }
        return detail
    }

    /// The owner is restoring with no job to name (an older daemon, or none registered yet).
    public static var restoringTerminals: String { text("longJobs.restoringTerminals", "Restoring your terminals") }

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "LongJobs", bundle: .module)
    }
}
