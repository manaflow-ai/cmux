import Foundation

extension CMUXCLI {
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
                "connectApps": CMUXDiffViewerLocalization.string("openChat.connectApps", defaultValue: "Connect your favorite apps to your agent"),
                "connectAppsUnavailable": CMUXDiffViewerLocalization.string("openChat.connectAppsUnavailable", defaultValue: "App connections are coming soon"),
                "environmentSelector": CMUXDiffViewerLocalization.string("openChat.environmentSelector", defaultValue: "Environment selector"),
                "exampleSuggestion": CMUXDiffViewerLocalization.string("openChat.exampleSuggestion", defaultValue: "Plan and build a polished feature from this workspace"),
                "headingFormat": CMUXDiffViewerLocalization.string("openChat.headingFormat", defaultValue: "What should we build in %@?"),
                "model": CMUXDiffViewerLocalization.string("openChat.model", defaultValue: "Model"),
                "modelDefault": CMUXDiffViewerLocalization.string("agentSession.web.modelDefault", defaultValue: "Default"),
                "modelEffort": CMUXDiffViewerLocalization.string("openChat.modelEffort", defaultValue: "Model and reasoning"),
                "reasoning": CMUXDiffViewerLocalization.string("openChat.reasoning", defaultValue: "Reasoning"),
                "noBranch": CMUXDiffViewerLocalization.string("openChat.noBranch", defaultValue: "No branch"),
                "placeholder": CMUXDiffViewerLocalization.string("openChat.placeholder", defaultValue: "Ask an agent to build, fix, or explore..."),
                "rateLimitSubtitleFormat": CMUXDiffViewerLocalization.string("openChat.rateLimitSubtitleFormat", defaultValue: "Your rate limit resets on %@. Upgrade or use one of your rate limit resets now."),
                "rateLimitTitle": CMUXDiffViewerLocalization.string("openChat.rateLimitTitle", defaultValue: "You're out of messages"),
                "reasoningExtraHigh": CMUXDiffViewerLocalization.string("openChat.reasoningExtraHigh", defaultValue: "Extra High"),
                "reasoningHigh": CMUXDiffViewerLocalization.string("openChat.reasoningHigh", defaultValue: "High"),
                "reasoningLow": CMUXDiffViewerLocalization.string("openChat.reasoningLow", defaultValue: "Low"),
                "reasoningMedium": CMUXDiffViewerLocalization.string("openChat.reasoningMedium", defaultValue: "Medium"),
                "repoSelector": CMUXDiffViewerLocalization.string("openChat.repoSelector", defaultValue: "Repository selector"),
                "resetUsage": CMUXDiffViewerLocalization.string("openChat.resetUsage", defaultValue: "Reset usage"),
                "resetUsageUnavailable": CMUXDiffViewerLocalization.string("openChat.resetUsageUnavailable", defaultValue: "Usage resets are coming soon"),
                "send": CMUXDiffViewerLocalization.string("openChat.send", defaultValue: "Send"),
                "submitUnavailableFormat": CMUXDiffViewerLocalization.string("openChat.submitUnavailableFormat", defaultValue: "Open Chat now sends from the native agent pane. Draft kept here: %@"),
                "title": CMUXDiffViewerLocalization.string("openChat.title", defaultValue: "Open Chat"),
                "voiceInput": CMUXDiffViewerLocalization.string("openChat.voiceInput", defaultValue: "Voice input"),
                "voiceUnavailable": CMUXDiffViewerLocalization.string("openChat.voiceUnavailable", defaultValue: "Voice input is not available yet"),
                "workLocally": CMUXDiffViewerLocalization.string("openChat.workLocally", defaultValue: "Work locally"),
            ])
        }
    }
}
