import Foundation

/// Localized labels supplied to the React checkpoint review. The page keeps
/// layout and selection state; the host supplies the locale through handshake.
public struct AgentPaneCheckpointStrings: Sendable {
    public nonisolated let values: [String: String]

    public nonisolated init() {
        values = [
            "title": String(localized: "agentPane.checkpoint.title", defaultValue: "Repository checkpoint", bundle: .module),
            "createCheckpoint": String(localized: "agentPane.checkpoint.createCheckpoint", defaultValue: "Create checkpoint", bundle: .module),
            "create": String(localized: "agentPane.checkpoint.create", defaultValue: "Create", bundle: .module),
            "cancel": String(localized: "agentPane.checkpoint.cancel", defaultValue: "Cancel", bundle: .module),
            "refresh": String(localized: "agentPane.checkpoint.refresh", defaultValue: "Refresh", bundle: .module),
            "loading": String(localized: "agentPane.checkpoint.loading", defaultValue: "Loading checkpoint options…", bundle: .module),
            "creating": String(localized: "agentPane.checkpoint.creating", defaultValue: "Creating checkpoint…", bundle: .module),
            "untracked": String(localized: "agentPane.checkpoint.untracked", defaultValue: "Untracked files", bundle: .module),
            "emptyUntracked": String(localized: "agentPane.checkpoint.emptyUntracked", defaultValue: "No eligible untracked files", bundle: .module),
            "included": String(localized: "agentPane.checkpoint.included", defaultValue: "Included", bundle: .module),
            "omitted": String(localized: "agentPane.checkpoint.omitted", defaultValue: "Omitted", bundle: .module),
            "unavailable": String(localized: "agentPane.checkpoint.unavailable", defaultValue: "Unavailable", bundle: .module),
            "reference": String(localized: "agentPane.checkpoint.reference", defaultValue: "Reference", bundle: .module),
            "base": String(localized: "agentPane.checkpoint.base", defaultValue: "Base", bundle: .module),
            "created": String(localized: "agentPane.checkpoint.created", defaultValue: "Created", bundle: .module),
            "expires": String(localized: "agentPane.checkpoint.expires", defaultValue: "Expires", bundle: .module),
            "pinned": String(localized: "agentPane.checkpoint.pinned", defaultValue: "Pinned", bundle: .module),
            "complete": String(localized: "agentPane.checkpoint.complete", defaultValue: "Complete", bundle: .module),
            "partial": String(localized: "agentPane.checkpoint.partial", defaultValue: "Partial checkpoint", bundle: .module),
            "skipped": String(localized: "agentPane.checkpoint.skipped", defaultValue: "Skipped files", bundle: .module),
            "copyReference": String(localized: "agentPane.checkpoint.copyReference", defaultValue: "Copy reference", bundle: .module),
            "copied": String(localized: "agentPane.checkpoint.copied", defaultValue: "Copied", bundle: .module),
            "keep": String(localized: "agentPane.checkpoint.keep", defaultValue: "Keep checkpoint", bundle: .module),
            "release": String(localized: "agentPane.checkpoint.release", defaultValue: "Release pin", bundle: .module),
            "manualRetention": String(localized: "agentPane.checkpoint.manualRetention", defaultValue: "Use Keep checkpoint before sharing this reference in a manual handoff.", bundle: .module),
            "failed": String(localized: "agentPane.checkpoint.failed", defaultValue: "Couldn’t complete this checkpoint request.", bundle: .module),
            "retry": String(localized: "agentPane.checkpoint.retry", defaultValue: "Retry", bundle: .module),
            "recovering": String(localized: "agentPane.checkpoint.recovering", defaultValue: "Checking the saved checkpoint…", bundle: .module),
            "ignored": String(localized: "agentPane.checkpoint.ignored", defaultValue: "Ignored", bundle: .module),
            "excluded": String(localized: "agentPane.checkpoint.excluded", defaultValue: "Excluded", bundle: .module),
            "tooLarge": String(localized: "agentPane.checkpoint.tooLarge", defaultValue: "Over the file size limit", bundle: .module),
            "notSelected": String(localized: "agentPane.checkpoint.notSelected", defaultValue: "Not selected", bundle: .module),
            "unavailableFile": String(localized: "agentPane.checkpoint.unavailableFile", defaultValue: "Unavailable file", bundle: .module),
            "bytes": String(localized: "agentPane.checkpoint.bytes", defaultValue: "Bytes", bundle: .module),
            "retained": String(localized: "agentPane.checkpoint.retained", defaultValue: "Retained", bundle: .module),
            "offline": String(localized: "agentPane.checkpoint.offline", defaultValue: "Reconnect before creating a checkpoint.", bundle: .module),
            "changed": String(localized: "agentPane.checkpoint.changed", defaultValue: "The repository changed. Refresh the checkpoint options.", bundle: .module),
            "unsupported": String(localized: "agentPane.checkpoint.unsupported", defaultValue: "Repository checkpoints are unavailable for this session.", bundle: .module),
            "noHead": String(localized: "agentPane.checkpoint.noHead", defaultValue: "No commit yet", bundle: .module),
        ]
    }
}
