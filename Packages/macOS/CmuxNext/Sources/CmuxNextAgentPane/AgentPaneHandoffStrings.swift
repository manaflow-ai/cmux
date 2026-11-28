import Foundation

/// Localized labels supplied to the React continuation review. The page owns
/// layout and interaction; keeping these labels in the host handshake makes
/// the native and web surfaces use the same locale without a second resource
/// loader.
public struct AgentPaneHandoffStrings: Sendable {
    public nonisolated let values: [String: String]

    public nonisolated init() {
        values = [
            "continueIn": String(localized: "agentPane.handoff.continueIn", defaultValue: "Continue in…", bundle: .module),
            "review": String(localized: "agentPane.handoff.review", defaultValue: "Review continuation", bundle: .module),
            "fromTo": String(localized: "agentPane.handoff.fromTo", defaultValue: "Continue from %@ in %@", bundle: .module),
            "context": String(localized: "agentPane.handoff.context", defaultValue: "Context to carry forward", bundle: .module),
            "checkpoint": String(localized: "agentPane.handoff.checkpoint", defaultValue: "Repository checkpoint", bundle: .module),
            "checkpointPlaceholder": String(localized: "agentPane.handoff.checkpointPlaceholder", defaultValue: "A saved commit, stash, or backup reference", bundle: .module),
            "checkpointConfirm": String(localized: "agentPane.handoff.checkpointConfirm", defaultValue: "I saved the working changes, including the files I need to keep.", bundle: .module),
            "memory": String(localized: "agentPane.handoff.memory", defaultValue: "Approved memory references", bundle: .module),
            "memoryHelp": String(localized: "agentPane.handoff.memoryHelp", defaultValue: "Share only the references you approve for this chat, one per line.", bundle: .module),
            "starting": String(localized: "agentPane.handoff.starting", defaultValue: "Starting…", bundle: .module),
            "continueTarget": String(localized: "agentPane.handoff.continueTarget", defaultValue: "Continue in %@", bundle: .module),
            "returnSource": String(localized: "agentPane.handoff.returnSource", defaultValue: "Back to source chat", bundle: .module),
            "discard": String(localized: "agentPane.handoff.discard", defaultValue: "Discard continuation", bundle: .module),
            "saving": String(localized: "agentPane.handoff.saving", defaultValue: "Saving review…", bundle: .module),
            "reload": String(localized: "agentPane.handoff.reload", defaultValue: "Reload saved review", bundle: .module),
            "coverage": String(localized: "agentPane.handoff.coverage", defaultValue: "Carried context", bundle: .module),
            "source": String(localized: "agentPane.handoff.source", defaultValue: "Source chat", bundle: .module),
            "target": String(localized: "agentPane.handoff.target", defaultValue: "Target chat", bundle: .module),
            "nativePolicy": String(localized: "agentPane.handoff.nativePolicy", defaultValue: "Native policy · isolation unverified", bundle: .module),
            "unverified": String(localized: "agentPane.handoff.unverified", defaultValue: "Coverage unverified", bundle: .module),
            "unverifiedDetail": String(localized: "agentPane.handoff.unverifiedDetail", defaultValue: "Filesystem and network isolation have not been verified for this session.", bundle: .module),
            "reviewContext": String(localized: "agentPane.handoff.reviewContext", defaultValue: "Review the context before continuing.", bundle: .module),
            "tooLarge": String(localized: "agentPane.handoff.tooLarge", defaultValue: "Keep the context below %@ bytes.", bundle: .module),
            "saveCheckpoint": String(localized: "agentPane.handoff.saveCheckpoint", defaultValue: "Save a repository checkpoint before continuing.", bundle: .module),
            "checkpointSingle": String(localized: "agentPane.handoff.checkpointSingle", defaultValue: "Use a single checkpoint reference.", bundle: .module),
            "memoryLimit": String(localized: "agentPane.handoff.memoryLimit", defaultValue: "Use at most 32 memory references, one per line.", bundle: .module),
            "failedReview": String(localized: "agentPane.handoff.failedReview", defaultValue: "Couldn’t review this continuation.", bundle: .module),
            "transcript": String(localized: "agentPane.handoff.transcript", defaultValue: "Transcript", bundle: .module),
            "tool_output": String(localized: "agentPane.handoff.toolOutput", defaultValue: "Tool output", bundle: .module),
            "plan": String(localized: "agentPane.handoff.plan", defaultValue: "Plan", bundle: .module),
            "files": String(localized: "agentPane.handoff.files", defaultValue: "Files", bundle: .module),
            "model": String(localized: "agentPane.handoff.model", defaultValue: "Model", bundle: .module),
            "included": String(localized: "agentPane.handoff.included", defaultValue: "Included", bundle: .module),
            "summarized": String(localized: "agentPane.handoff.summarized", defaultValue: "Summarized", bundle: .module),
            "omitted": String(localized: "agentPane.handoff.omitted", defaultValue: "Omitted", bundle: .module),
            "unavailable": String(localized: "agentPane.handoff.unavailable", defaultValue: "Unavailable", bundle: .module),
        ]
    }
}
