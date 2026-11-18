import Foundation

/// Localized labels supplied to the React checkpoint review. The page keeps
/// layout and selection state; the host supplies the locale through handshake.
public struct AgentPaneCheckpointStrings: Sendable {
    public nonisolated let values: [String: String]

    public nonisolated init() {
        values = [
            "title": String(localized: "agentPane.checkpoint.title", defaultValue: "Repository checkpoint", bundle: .l10n),
            "createCheckpoint": String(localized: "agentPane.checkpoint.createCheckpoint", defaultValue: "Create checkpoint", bundle: .l10n),
            "create": String(localized: "agentPane.checkpoint.create", defaultValue: "Create", bundle: .l10n),
            "cancel": String(localized: "agentPane.checkpoint.cancel", defaultValue: "Cancel", bundle: .l10n),
            "refresh": String(localized: "agentPane.checkpoint.refresh", defaultValue: "Refresh", bundle: .l10n),
            "loading": String(localized: "agentPane.checkpoint.loading", defaultValue: "Loading checkpoint options…", bundle: .l10n),
            "creating": String(localized: "agentPane.checkpoint.creating", defaultValue: "Creating checkpoint…", bundle: .l10n),
            "untracked": String(localized: "agentPane.checkpoint.untracked", defaultValue: "Untracked files", bundle: .l10n),
            "emptyUntracked": String(localized: "agentPane.checkpoint.emptyUntracked", defaultValue: "No eligible untracked files", bundle: .l10n),
            "included": String(localized: "agentPane.checkpoint.included", defaultValue: "Included", bundle: .l10n),
            "omitted": String(localized: "agentPane.checkpoint.omitted", defaultValue: "Omitted", bundle: .l10n),
            "unavailable": String(localized: "agentPane.checkpoint.unavailable", defaultValue: "Unavailable", bundle: .l10n),
            "reference": String(localized: "agentPane.checkpoint.reference", defaultValue: "Reference", bundle: .l10n),
            "base": String(localized: "agentPane.checkpoint.base", defaultValue: "Base", bundle: .l10n),
            "created": String(localized: "agentPane.checkpoint.created", defaultValue: "Created", bundle: .l10n),
            "expires": String(localized: "agentPane.checkpoint.expires", defaultValue: "Expires", bundle: .l10n),
            "pinned": String(localized: "agentPane.checkpoint.pinned", defaultValue: "Pinned", bundle: .l10n),
            "complete": String(localized: "agentPane.checkpoint.complete", defaultValue: "Complete", bundle: .l10n),
            "partial": String(localized: "agentPane.checkpoint.partial", defaultValue: "Partial checkpoint", bundle: .l10n),
            "skipped": String(localized: "agentPane.checkpoint.skipped", defaultValue: "Skipped files", bundle: .l10n),
            "copyReference": String(localized: "agentPane.checkpoint.copyReference", defaultValue: "Copy reference", bundle: .l10n),
            "copied": String(localized: "agentPane.checkpoint.copied", defaultValue: "Copied", bundle: .l10n),
            "keep": String(localized: "agentPane.checkpoint.keep", defaultValue: "Keep checkpoint", bundle: .l10n),
            "release": String(localized: "agentPane.checkpoint.release", defaultValue: "Release pin", bundle: .l10n),
            "manualRetention": String(localized: "agentPane.checkpoint.manualRetention", defaultValue: "Use Keep checkpoint before sharing this reference in a manual handoff.", bundle: .l10n),
            "failed": String(localized: "agentPane.checkpoint.failed", defaultValue: "Couldn’t complete this checkpoint request.", bundle: .l10n),
            "retry": String(localized: "agentPane.checkpoint.retry", defaultValue: "Retry", bundle: .l10n),
            "recovering": String(localized: "agentPane.checkpoint.recovering", defaultValue: "Checking the saved checkpoint…", bundle: .l10n),
            "ignored": String(localized: "agentPane.checkpoint.ignored", defaultValue: "Ignored", bundle: .l10n),
            "excluded": String(localized: "agentPane.checkpoint.excluded", defaultValue: "Excluded", bundle: .l10n),
            "tooLarge": String(localized: "agentPane.checkpoint.tooLarge", defaultValue: "Over the file size limit", bundle: .l10n),
            "notSelected": String(localized: "agentPane.checkpoint.notSelected", defaultValue: "Not selected", bundle: .l10n),
            "unavailableFile": String(localized: "agentPane.checkpoint.unavailableFile", defaultValue: "Unavailable file", bundle: .l10n),
            "bytes": String(localized: "agentPane.checkpoint.bytes", defaultValue: "Bytes", bundle: .l10n),
            "retained": String(localized: "agentPane.checkpoint.retained", defaultValue: "Retained", bundle: .l10n),
            "offline": String(localized: "agentPane.checkpoint.offline", defaultValue: "Reconnect before creating a checkpoint.", bundle: .l10n),
            "changed": String(localized: "agentPane.checkpoint.changed", defaultValue: "The repository changed. Refresh the checkpoint options.", bundle: .l10n),
            "unsupported": String(localized: "agentPane.checkpoint.unsupported", defaultValue: "Repository checkpoints are unavailable for this session.", bundle: .l10n),
            "noHead": String(localized: "agentPane.checkpoint.noHead", defaultValue: "No commit yet", bundle: .l10n),
        ]
    }
}
