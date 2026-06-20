import Foundation

extension CMUXCLI {
    struct OpenChatContext {
        var workspaceName: String
        var repoName: String
        var repoRoot: String?
        var branchName: String?
        var branchLabel: String
    }

    struct OpenChatLabels {
        var values: [String: String]

        var jsonObject: [String: Any] {
            values
        }

        static func localized() -> OpenChatLabels {
            OpenChatLabels(values: [
                "accountSwitcher": CMUXDiffViewerLocalization.string("openChat.accountSwitcher", defaultValue: "Account and model switcher"),
                "addCredits": CMUXDiffViewerLocalization.string("openChat.addCredits", defaultValue: "Add Credits"),
                "addCreditsUnavailable": CMUXDiffViewerLocalization.string("openChat.addCreditsUnavailable", defaultValue: "Credits are coming soon"),
                "approvalMode": CMUXDiffViewerLocalization.string("openChat.approvalMode", defaultValue: "Approval mode"),
                "approvalAutoReview": CMUXDiffViewerLocalization.string("openChat.approvalAutoReview", defaultValue: "Auto-review"),
                "approvalDefault": CMUXDiffViewerLocalization.string("openChat.approvalDefault", defaultValue: "Default"),
                "approvalFullAccess": CMUXDiffViewerLocalization.string("openChat.approvalFullAccess", defaultValue: "Full access"),
                "approvalReadOnly": CMUXDiffViewerLocalization.string("openChat.approvalReadOnly", defaultValue: "Read only"),
                "attachContext": CMUXDiffViewerLocalization.string("openChat.attachContext", defaultValue: "Attach context"),
                "branchSelector": CMUXDiffViewerLocalization.string("openChat.branchSelector", defaultValue: "Branch selector"),
                "connectApps": CMUXDiffViewerLocalization.string("openChat.connectApps", defaultValue: "Connect your favorite apps to Codex"),
                "connectAppsUnavailable": CMUXDiffViewerLocalization.string("openChat.connectAppsUnavailable", defaultValue: "App connections are coming soon"),
                "environmentSelector": CMUXDiffViewerLocalization.string("openChat.environmentSelector", defaultValue: "Environment selector"),
                "exampleSuggestion": CMUXDiffViewerLocalization.string("openChat.exampleSuggestion", defaultValue: "Plan and build a polished feature from this workspace"),
                "headingFormat": CMUXDiffViewerLocalization.string("openChat.headingFormat", defaultValue: "What should we build in %@?"),
                "model": CMUXDiffViewerLocalization.string("openChat.model", defaultValue: "Model"),
                "modelEffort": CMUXDiffViewerLocalization.string("openChat.modelEffort", defaultValue: "Model and reasoning"),
                "reasoning": CMUXDiffViewerLocalization.string("openChat.reasoning", defaultValue: "Reasoning"),
                "noBranch": CMUXDiffViewerLocalization.string("openChat.noBranch", defaultValue: "No branch"),
                "placeholder": CMUXDiffViewerLocalization.string("openChat.placeholder", defaultValue: "Ask Codex to build, fix, or explore..."),
                "rateLimitSubtitleFormat": CMUXDiffViewerLocalization.string("openChat.rateLimitSubtitleFormat", defaultValue: "Your rate limit resets on %@. Upgrade or use one of your rate limit resets now."),
                "rateLimitTitle": CMUXDiffViewerLocalization.string("openChat.rateLimitTitle", defaultValue: "You're out of Codex messages"),
                "reasoningExtraHigh": CMUXDiffViewerLocalization.string("openChat.reasoningExtraHigh", defaultValue: "Extra High"),
                "reasoningHigh": CMUXDiffViewerLocalization.string("openChat.reasoningHigh", defaultValue: "High"),
                "reasoningLow": CMUXDiffViewerLocalization.string("openChat.reasoningLow", defaultValue: "Low"),
                "reasoningMedium": CMUXDiffViewerLocalization.string("openChat.reasoningMedium", defaultValue: "Medium"),
                "repoSelector": CMUXDiffViewerLocalization.string("openChat.repoSelector", defaultValue: "Repository selector"),
                "resetUsage": CMUXDiffViewerLocalization.string("openChat.resetUsage", defaultValue: "Reset usage"),
                "resetUsageUnavailable": CMUXDiffViewerLocalization.string("openChat.resetUsageUnavailable", defaultValue: "Usage resets are coming soon"),
                "send": CMUXDiffViewerLocalization.string("openChat.send", defaultValue: "Send"),
                "submitUnavailableFormat": CMUXDiffViewerLocalization.string("openChat.submitUnavailableFormat", defaultValue: "Chat backend is coming soon. Draft kept here: %@"),
                "title": CMUXDiffViewerLocalization.string("openChat.title", defaultValue: "Open Chat"),
                "voiceInput": CMUXDiffViewerLocalization.string("openChat.voiceInput", defaultValue: "Voice input"),
                "voiceUnavailable": CMUXDiffViewerLocalization.string("openChat.voiceUnavailable", defaultValue: "Voice input is not available yet"),
                "workLocally": CMUXDiffViewerLocalization.string("openChat.workLocally", defaultValue: "Work locally"),
            ])
        }
    }

    func openChatContext(cwd: String, workspaceName: String?) -> OpenChatContext {
        let resolvedCWD = standardizedDiffSourcePath(cwd)
        let repoRoot = try? gitRepoRoot(startingAt: resolvedCWD)
        let repoLabelPath = repoRoot ?? resolvedCWD
        let repoName = openChatDisplayName(forPath: repoLabelPath)
        let workspaceLabel = normalizedDiffSourceValue(workspaceName) ?? repoName
        let branchName = repoRoot.flatMap(openChatCurrentBranch(in:))
        let branchLabel = branchName ?? OpenChatLabels.localized().values["noBranch"] ?? "No branch"
        return OpenChatContext(
            workspaceName: workspaceLabel,
            repoName: repoName,
            repoRoot: repoRoot,
            branchName: branchName,
            branchLabel: branchLabel
        )
    }

    private func openChatDisplayName(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cmux" : path
    }

    private func openChatCurrentBranch(in repoRoot: String) -> String? {
        if let branch = try? gitSingleLine(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot),
           branch != "HEAD",
           !branch.isEmpty {
            return branch
        }
        return try? gitSingleLine(["rev-parse", "--short", "HEAD"], in: repoRoot)
    }
}
