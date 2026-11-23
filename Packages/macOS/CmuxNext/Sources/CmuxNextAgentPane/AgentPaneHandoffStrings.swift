import Foundation

/// Localized labels supplied to the React continuation review. The page owns
/// layout and interaction; keeping these labels in the host handshake makes
/// the native and web surfaces use the same locale without a second resource
/// loader.
public struct AgentPaneHandoffStrings: Sendable {
    public nonisolated let values: [String: String]

    public nonisolated init() {
        values = [
            "continueIn": String(localized: "agentPane.handoff.continueIn", defaultValue: "Continue In…", bundle: .localizedModule),
            "review": String(localized: "agentPane.handoff.review", defaultValue: "Review continuation", bundle: .localizedModule),
            "fromTo": String(localized: "agentPane.handoff.fromTo", defaultValue: "Continue from %@ in %@", bundle: .localizedModule),
            "context": String(localized: "agentPane.handoff.context", defaultValue: "Context to carry forward", bundle: .localizedModule),
            "checkpoint": String(localized: "agentPane.handoff.checkpoint", defaultValue: "Repository checkpoint", bundle: .localizedModule),
            "checkpointPlaceholder": String(localized: "agentPane.handoff.checkpointPlaceholder", defaultValue: "Commit, stash or backup", bundle: .localizedModule),
            "checkpointConfirm": String(localized: "agentPane.handoff.checkpointConfirm", defaultValue: "I saved the working changes, including the files I need to keep.", bundle: .localizedModule),
            "memory": String(localized: "agentPane.handoff.memory", defaultValue: "Approved memory references", bundle: .localizedModule),
            "memoryHelp": String(localized: "agentPane.handoff.memoryHelp", defaultValue: "Share only the references you approve for this chat, one per line.", bundle: .localizedModule),
            "starting": String(localized: "agentPane.handoff.starting", defaultValue: "Starting…", bundle: .localizedModule),
            "continueTarget": String(localized: "agentPane.handoff.continueTarget", defaultValue: "Continue in %@", bundle: .localizedModule),
            "returnSource": String(localized: "agentPane.handoff.returnSource", defaultValue: "Back to source chat", bundle: .localizedModule),
            "discard": String(localized: "agentPane.handoff.discard", defaultValue: "Discard continuation", bundle: .localizedModule),
            "saving": String(localized: "agentPane.handoff.saving", defaultValue: "Saving review…", bundle: .localizedModule),
            "reload": String(localized: "agentPane.handoff.reload", defaultValue: "Reload saved review", bundle: .localizedModule),
            "coverage": String(localized: "agentPane.handoff.coverage", defaultValue: "Carried context", bundle: .localizedModule),
            "source": String(localized: "agentPane.handoff.source", defaultValue: "Source chat", bundle: .localizedModule),
            "target": String(localized: "agentPane.handoff.target", defaultValue: "Target chat", bundle: .localizedModule),
            "nativePolicy": String(localized: "agentPane.handoff.nativePolicy", defaultValue: "Native policy · isolation unverified", bundle: .localizedModule),
            "unverifiedDetail": String(localized: "agentPane.handoff.unverifiedDetail", defaultValue: "Filesystem and network isolation have not been verified for this session.", bundle: .localizedModule),
            "reviewContext": String(localized: "agentPane.handoff.reviewContext", defaultValue: "Review the context before continuing.", bundle: .localizedModule),
            "tooLarge": String(localized: "agentPane.handoff.tooLarge", defaultValue: "Keep the context below %@ bytes.", bundle: .localizedModule),
            "saveCheckpoint": String(localized: "agentPane.handoff.saveCheckpoint", defaultValue: "Save a repository checkpoint before continuing.", bundle: .localizedModule),
            "checkpointSingle": String(localized: "agentPane.handoff.checkpointSingle", defaultValue: "Use a single checkpoint reference.", bundle: .localizedModule),
            "memoryLimit": String(localized: "agentPane.handoff.memoryLimit", defaultValue: "Use at most 32 memory references, one per line.", bundle: .localizedModule),
            "failedReview": String(localized: "agentPane.handoff.failedReview", defaultValue: "Couldn’t review this continuation.", bundle: .localizedModule),
            "transcript": String(localized: "agentPane.handoff.transcript", defaultValue: "Transcript", bundle: .localizedModule),
            "tool_output": String(localized: "agentPane.handoff.toolOutput", defaultValue: "Tool output", bundle: .localizedModule),
            "plan": String(localized: "agentPane.handoff.plan", defaultValue: "Plan", bundle: .localizedModule),
            "files": String(localized: "agentPane.handoff.files", defaultValue: "Files", bundle: .localizedModule),
            "model": String(localized: "agentPane.handoff.model", defaultValue: "Model", bundle: .localizedModule),
            "included": String(localized: "agentPane.handoff.included", defaultValue: "Included", bundle: .localizedModule),
            "summarized": String(localized: "agentPane.handoff.summarized", defaultValue: "Summarized", bundle: .localizedModule),
            "omitted": String(localized: "agentPane.handoff.omitted", defaultValue: "Omitted", bundle: .localizedModule),
            "unavailable": String(localized: "agentPane.handoff.unavailable", defaultValue: "Unavailable", bundle: .localizedModule),
        ]
    }
}
