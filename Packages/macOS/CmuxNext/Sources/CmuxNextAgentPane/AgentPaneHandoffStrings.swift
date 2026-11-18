import Foundation

/// Localized labels supplied to the React continuation review. The page owns
/// layout and interaction; keeping these labels in the host handshake makes
/// the native and web surfaces use the same locale without a second resource
/// loader.
public struct AgentPaneHandoffStrings: Sendable {
    public nonisolated let values: [String: String]

    public nonisolated init() {
        values = [
            "continueIn": String(localized: "agentPane.handoff.continueIn", defaultValue: "Continue In…", bundle: .l10n),
            "review": String(localized: "agentPane.handoff.review", defaultValue: "Review continuation", bundle: .l10n),
            "fromTo": String(localized: "agentPane.handoff.fromTo", defaultValue: "Continue from %@ in %@", bundle: .l10n),
            "context": String(localized: "agentPane.handoff.context", defaultValue: "Context to carry forward", bundle: .l10n),
            "checkpoint": String(localized: "agentPane.handoff.checkpoint", defaultValue: "Repository checkpoint", bundle: .l10n),
            "checkpointPlaceholder": String(localized: "agentPane.handoff.checkpointPlaceholder", defaultValue: "A saved commit, stash, or backup reference", bundle: .l10n),
            "checkpointConfirm": String(localized: "agentPane.handoff.checkpointConfirm", defaultValue: "I saved the working changes, including the files I need to keep.", bundle: .l10n),
            "memory": String(localized: "agentPane.handoff.memory", defaultValue: "Approved memory references", bundle: .l10n),
            "memoryHelp": String(localized: "agentPane.handoff.memoryHelp", defaultValue: "Share only the references you approve for this chat, one per line.", bundle: .l10n),
            "starting": String(localized: "agentPane.handoff.starting", defaultValue: "Starting…", bundle: .l10n),
            "continueTarget": String(localized: "agentPane.handoff.continueTarget", defaultValue: "Continue in %@", bundle: .l10n),
            "returnSource": String(localized: "agentPane.handoff.returnSource", defaultValue: "Back to source chat", bundle: .l10n),
            "discard": String(localized: "agentPane.handoff.discard", defaultValue: "Discard continuation", bundle: .l10n),
            "saving": String(localized: "agentPane.handoff.saving", defaultValue: "Saving review…", bundle: .l10n),
            "reload": String(localized: "agentPane.handoff.reload", defaultValue: "Reload saved review", bundle: .l10n),
            "coverage": String(localized: "agentPane.handoff.coverage", defaultValue: "Carried context", bundle: .l10n),
            "source": String(localized: "agentPane.handoff.source", defaultValue: "Source chat", bundle: .l10n),
            "target": String(localized: "agentPane.handoff.target", defaultValue: "Target chat", bundle: .l10n),
            "nativePolicy": String(localized: "agentPane.handoff.nativePolicy", defaultValue: "Native policy · isolation unverified", bundle: .l10n),
            "unverifiedDetail": String(localized: "agentPane.handoff.unverifiedDetail", defaultValue: "Filesystem and network isolation have not been verified for this session.", bundle: .l10n),
            "reviewContext": String(localized: "agentPane.handoff.reviewContext", defaultValue: "Review the context before continuing.", bundle: .l10n),
            "tooLarge": String(localized: "agentPane.handoff.tooLarge", defaultValue: "Keep the context below %@ bytes.", bundle: .l10n),
            "saveCheckpoint": String(localized: "agentPane.handoff.saveCheckpoint", defaultValue: "Save a repository checkpoint before continuing.", bundle: .l10n),
            "checkpointSingle": String(localized: "agentPane.handoff.checkpointSingle", defaultValue: "Use a single checkpoint reference.", bundle: .l10n),
            "memoryLimit": String(localized: "agentPane.handoff.memoryLimit", defaultValue: "Use at most 32 memory references, one per line.", bundle: .l10n),
            "failedReview": String(localized: "agentPane.handoff.failedReview", defaultValue: "Couldn’t review this continuation.", bundle: .l10n),
            "transcript": String(localized: "agentPane.handoff.transcript", defaultValue: "Transcript", bundle: .l10n),
            "tool_output": String(localized: "agentPane.handoff.toolOutput", defaultValue: "Tool output", bundle: .l10n),
            "plan": String(localized: "agentPane.handoff.plan", defaultValue: "Plan", bundle: .l10n),
            "files": String(localized: "agentPane.handoff.files", defaultValue: "Files", bundle: .l10n),
            "model": String(localized: "agentPane.handoff.model", defaultValue: "Model", bundle: .l10n),
            "included": String(localized: "agentPane.handoff.included", defaultValue: "Included", bundle: .l10n),
            "summarized": String(localized: "agentPane.handoff.summarized", defaultValue: "Summarized", bundle: .l10n),
            "omitted": String(localized: "agentPane.handoff.omitted", defaultValue: "Omitted", bundle: .l10n),
            "unavailable": String(localized: "agentPane.handoff.unavailable", defaultValue: "Unavailable", bundle: .l10n),
        ]
    }
}
