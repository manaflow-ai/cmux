import Foundation

/// Localized labels supplied to the React checkpoint review. The page keeps
/// layout and selection state; the host supplies the locale through handshake.
public struct AgentPaneCheckpointStrings: Sendable {
    public nonisolated let values: [String: String]

    public nonisolated init() {
        values = [
            "title": String(localized: "agentPane.checkpoint.title", defaultValue: "Repository checkpoint", bundle: .localizedModule),
            "createCheckpoint": String(localized: "agentPane.checkpoint.createCheckpoint", defaultValue: "Create checkpoint", bundle: .localizedModule),
            "create": String(localized: "agentPane.checkpoint.create", defaultValue: "Create", bundle: .localizedModule),
            "cancel": String(localized: "agentPane.checkpoint.cancel", defaultValue: "Cancel", bundle: .localizedModule),
            "refresh": String(localized: "agentPane.checkpoint.refresh", defaultValue: "Refresh", bundle: .localizedModule),
            "loading": String(localized: "agentPane.checkpoint.loading", defaultValue: "Loading checkpoint options…", bundle: .localizedModule),
            "creating": String(localized: "agentPane.checkpoint.creating", defaultValue: "Creating checkpoint…", bundle: .localizedModule),
            "untracked": String(localized: "agentPane.checkpoint.untracked", defaultValue: "Untracked files", bundle: .localizedModule),
            "emptyUntracked": String(localized: "agentPane.checkpoint.emptyUntracked", defaultValue: "No eligible untracked files", bundle: .localizedModule),
            "included": String(localized: "agentPane.checkpoint.included", defaultValue: "Included", bundle: .localizedModule),
            "omitted": String(localized: "agentPane.checkpoint.omitted", defaultValue: "Omitted", bundle: .localizedModule),
            "unavailable": String(localized: "agentPane.checkpoint.unavailable", defaultValue: "Unavailable", bundle: .localizedModule),
            "reference": String(localized: "agentPane.checkpoint.reference", defaultValue: "Reference", bundle: .localizedModule),
            "base": String(localized: "agentPane.checkpoint.base", defaultValue: "Base", bundle: .localizedModule),
            "created": String(localized: "agentPane.checkpoint.created", defaultValue: "Created", bundle: .localizedModule),
            "expires": String(localized: "agentPane.checkpoint.expires", defaultValue: "Expires", bundle: .localizedModule),
            "pinned": String(localized: "agentPane.checkpoint.pinned", defaultValue: "Pinned", bundle: .localizedModule),
            "complete": String(localized: "agentPane.checkpoint.complete", defaultValue: "Complete", bundle: .localizedModule),
            "partial": String(localized: "agentPane.checkpoint.partial", defaultValue: "Partial checkpoint", bundle: .localizedModule),
            "skipped": String(localized: "agentPane.checkpoint.skipped", defaultValue: "Skipped files", bundle: .localizedModule),
            "copyReference": String(localized: "agentPane.checkpoint.copyReference", defaultValue: "Copy reference", bundle: .localizedModule),
            "copied": String(localized: "agentPane.checkpoint.copied", defaultValue: "Copied", bundle: .localizedModule),
            "keep": String(localized: "agentPane.checkpoint.keep", defaultValue: "Keep checkpoint", bundle: .localizedModule),
            "release": String(localized: "agentPane.checkpoint.release", defaultValue: "Release pin", bundle: .localizedModule),
            "manualRetention": String(localized: "agentPane.checkpoint.manualRetention", defaultValue: "Use Keep checkpoint before sharing this reference in a manual handoff.", bundle: .localizedModule),
            // retry-prompt-ok: creating or pinning a checkpoint the person asked for writes git refs (a side effect); drawn by webviews
            "failed": String(localized: "agentPane.checkpoint.failed", defaultValue: "Couldn’t complete this checkpoint request.", bundle: .localizedModule),
            "retry": String(localized: "agentPane.checkpoint.retry", defaultValue: "Retry", bundle: .localizedModule),
            "recovering": String(localized: "agentPane.checkpoint.recovering", defaultValue: "Checking the saved checkpoint…", bundle: .localizedModule),
            "ignored": String(localized: "agentPane.checkpoint.ignored", defaultValue: "Ignored", bundle: .localizedModule),
            "excluded": String(localized: "agentPane.checkpoint.excluded", defaultValue: "Excluded", bundle: .localizedModule),
            "tooLarge": String(localized: "agentPane.checkpoint.tooLarge", defaultValue: "Over the file size limit", bundle: .localizedModule),
            "notSelected": String(localized: "agentPane.checkpoint.notSelected", defaultValue: "Not selected", bundle: .localizedModule),
            "unavailableFile": String(localized: "agentPane.checkpoint.unavailableFile", defaultValue: "Unavailable file", bundle: .localizedModule),
            "bytes": String(localized: "agentPane.checkpoint.bytes", defaultValue: "Bytes", bundle: .localizedModule),
            // retry-prompt-ok: creating a checkpoint writes git refs; the chat reconnects by itself, the create is the person's
            "retained": String(localized: "agentPane.checkpoint.retained", defaultValue: "Retained", bundle: .localizedModule),
            "offline": String(localized: "agentPane.checkpoint.offline", defaultValue: "Reconnect before creating a checkpoint.", bundle: .localizedModule),
            "changed": String(localized: "agentPane.checkpoint.changed", defaultValue: "The repository changed. Refresh the checkpoint options.", bundle: .localizedModule),
            "unsupported": String(localized: "agentPane.checkpoint.unsupported", defaultValue: "Repository checkpoints are unavailable for this session.", bundle: .localizedModule),
            "noHead": String(localized: "agentPane.checkpoint.noHead", defaultValue: "No commit yet", bundle: .localizedModule),
        ]
    }
}
