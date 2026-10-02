import Foundation

/// Localized labels supplied to the React continuation review. The page owns
/// layout and interaction; keeping these labels in the host handshake makes
/// the native and web surfaces use the same locale without a second resource
/// loader.
public enum AgentPaneHandoffStrings {
    public static let values: [String: String] = [
        "continueIn": t("agentPane.handoff.continueIn", "Continue in…"),
        "review": t("agentPane.handoff.review", "Review continuation"),
        "fromTo": t("agentPane.handoff.fromTo", "Continue from %@ in %@"),
        "context": t("agentPane.handoff.context", "Context to carry forward"),
        "checkpoint": t("agentPane.handoff.checkpoint", "Repository checkpoint"),
        "checkpointPlaceholder": t("agentPane.handoff.checkpointPlaceholder", "A saved commit, stash, or backup reference"),
        "checkpointConfirm": t("agentPane.handoff.checkpointConfirm", "I saved the working changes, including the files I need to keep."),
        "memory": t("agentPane.handoff.memory", "Approved memory references"),
        "memoryHelp": t("agentPane.handoff.memoryHelp", "Share only the references you approve for this chat, one per line."),
        "starting": t("agentPane.handoff.starting", "Starting…"),
        "continueTarget": t("agentPane.handoff.continueTarget", "Continue in %@"),
        "returnSource": t("agentPane.handoff.returnSource", "Back to source chat"),
        "discard": t("agentPane.handoff.discard", "Discard continuation"),
        "saving": t("agentPane.handoff.saving", "Saving review…"),
        "reload": t("agentPane.handoff.reload", "Reload saved review"),
        "coverage": t("agentPane.handoff.coverage", "Carried context"),
        "source": t("agentPane.handoff.source", "Source chat"),
        "target": t("agentPane.handoff.target", "Target chat"),
        "nativePolicy": t("agentPane.handoff.nativePolicy", "Native policy · isolation unverified"),
        "unverified": t("agentPane.handoff.unverified", "Coverage unverified"),
        "unverifiedDetail": t("agentPane.handoff.unverifiedDetail", "Filesystem and network isolation have not been verified for this session."),
        "reviewContext": t("agentPane.handoff.reviewContext", "Review the context before continuing."),
        "tooLarge": t("agentPane.handoff.tooLarge", "Keep the context below %@ bytes."),
        "saveCheckpoint": t("agentPane.handoff.saveCheckpoint", "Save a repository checkpoint before continuing."),
        "checkpointSingle": t("agentPane.handoff.checkpointSingle", "Use a single checkpoint reference."),
        "memoryLimit": t("agentPane.handoff.memoryLimit", "Use at most 32 memory references, one per line."),
        "failedReview": t("agentPane.handoff.failedReview", "Couldn’t review this continuation."),
        "transcript": t("agentPane.handoff.transcript", "Transcript"),
        "tool_output": t("agentPane.handoff.toolOutput", "Tool output"),
        "plan": t("agentPane.handoff.plan", "Plan"),
        "files": t("agentPane.handoff.files", "Files"),
        "model": t("agentPane.handoff.model", "Model"),
        "included": t("agentPane.handoff.included", "Included"),
        "summarized": t("agentPane.handoff.summarized", "Summarized"),
        "omitted": t("agentPane.handoff.omitted", "Omitted"),
        "unavailable": t("agentPane.handoff.unavailable", "Unavailable"),
    ]

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
