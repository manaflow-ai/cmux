import CmuxAgentChat
import Foundation

extension AgentSessionWebContextCopy {
    /// Builds the renderer copy table with every string resolved against the app bundle.
    ///
    /// `String(localized:)` runs app-side so the app bundle's `Localizable.xcstrings` supplies
    /// non-English translations; resolving inside `CmuxAgentChat` would bind to the package
    /// bundle and silently drop them.
    static func localized() -> AgentSessionWebContextCopy {
        AgentSessionWebContextCopy(entries: [
            "start": String(localized: "agentSession.web.start", defaultValue: "Start"),
            "stop": String(localized: "agentSession.web.stop", defaultValue: "Stop"),
            "send": String(localized: "agentSession.web.send", defaultValue: "Send"),
            "provider": String(localized: "agentSession.web.provider", defaultValue: "Provider"),
            "rateLimits": String(localized: "agentSession.web.rateLimits", defaultValue: "Rate limits"),
            "rateLimitUsageRemaining": String(
                localized: "agentSession.web.rateLimit.usageRemaining",
                defaultValue: "Usage remaining"
            ),
            "rateLimitPrimary": String(localized: "agentSession.web.rateLimit.primary", defaultValue: "Primary"),
            "rateLimitSecondary": String(localized: "agentSession.web.rateLimit.secondary", defaultValue: "Secondary"),
            "rateLimitWeekly": String(localized: "agentSession.web.rateLimit.weekly", defaultValue: "Weekly"),
            "rateLimitMonthly": String(localized: "agentSession.web.rateLimit.monthly", defaultValue: "Monthly"),
            "rateLimitDaysFormat": String(localized: "agentSession.web.rateLimit.daysFormat", defaultValue: "%@d"),
            "rateLimitHoursFormat": String(localized: "agentSession.web.rateLimit.hoursFormat", defaultValue: "%@h"),
            "rateLimitMinutesFormat": String(localized: "agentSession.web.rateLimit.minutesFormat", defaultValue: "%@m"),
            "rateLimitResets": String(localized: "agentSession.web.rateLimit.resets", defaultValue: "resets"),
            "voiceInput": String(localized: "agentSession.web.voiceInput", defaultValue: "Voice input"),
            "promptPlaceholder": String(
                localized: "agentSession.web.promptPlaceholder",
                defaultValue: "Ask anything"
            ),
            "attachFile": String(
                localized: "agentSession.web.attachFile",
                defaultValue: "Attach file"
            ),
            "addFilesAndMore": String(
                localized: "agentSession.web.addFilesAndMore",
                defaultValue: "Add files and more"
            ),
            "addPhotosAndFiles": String(
                localized: "agentSession.web.addPhotosAndFiles",
                defaultValue: "Add photos & files"
            ),
            "removeAttachment": String(
                localized: "agentSession.web.removeAttachment",
                defaultValue: "Remove attachment"
            ),
            "copyOutput": String(
                localized: "agentSession.web.copyOutput",
                defaultValue: "Copy output"
            ),
            "copyAssistantMessage": String(
                localized: "agentSession.web.copyAssistantMessage",
                defaultValue: "Copy"
            ),
            "copiedAssistantMessage": String(
                localized: "agentSession.web.copiedAssistantMessage",
                defaultValue: "Copied"
            ),
            "copyUserMessage": String(
                localized: "agentSession.web.copyUserMessage",
                defaultValue: "Copy message"
            ),
            "copiedUserMessage": String(
                localized: "agentSession.web.copiedUserMessage",
                defaultValue: "Copied"
            ),
            "shellLabel": String(
                localized: "agentSession.web.shellLabel",
                defaultValue: "Shell"
            ),
            "copyShellContents": String(
                localized: "agentSession.web.copyShellContents",
                defaultValue: "Copy shell contents"
            ),
            "copiedShellContents": String(
                localized: "agentSession.web.copiedShellContents",
                defaultValue: "Copied shell contents"
            ),
            "collapseShell": String(
                localized: "agentSession.web.collapseShell",
                defaultValue: "Collapse shell"
            ),
            "shellSuccess": String(
                localized: "agentSession.web.shellSuccess",
                defaultValue: "Success"
            ),
            "showMore": String(
                localized: "agentSession.web.showMore",
                defaultValue: "Show more"
            ),
            "showLess": String(
                localized: "agentSession.web.showLess",
                defaultValue: "Show less"
            ),
            "browseWeb": String(localized: "agentSession.web.browseWeb", defaultValue: "Browse web"),
            "autoContext": String(localized: "agentSession.web.autoContext", defaultValue: "Context"),
            "includeIdeContext": String(
                localized: "agentSession.web.includeIdeContext",
                defaultValue: "Include IDE context"
            ),
            "ideContext": String(
                localized: "agentSession.web.ideContext",
                defaultValue: "IDE context"
            ),
            "tools": String(localized: "agentSession.web.tools", defaultValue: "Tools"),
            "changePermissions": String(
                localized: "agentSession.web.changePermissions",
                defaultValue: "Change permissions"
            ),
            "permissionsDefault": String(
                localized: "agentSession.web.permissions.default",
                defaultValue: "Default permissions"
            ),
            "permissionsFullAccess": String(
                localized: "agentSession.web.permissions.fullAccess",
                defaultValue: "Full access"
            ),
            "permissionsAutoReview": String(
                localized: "agentSession.web.permissions.autoReview",
                defaultValue: "Auto-review"
            ),
            "permissionsCustom": String(
                localized: "agentSession.web.permissions.custom",
                defaultValue: "Custom (config.toml)"
            ),
            "reasoningEffortHigh": String(
                localized: "agentSession.web.reasoningEffort.high",
                defaultValue: "High"
            ),
            "mentionMenuTitle": String(
                localized: "agentSession.web.mentionMenuTitle",
                defaultValue: "Mention"
            ),
            "mentionCurrentWorkspace": String(
                localized: "agentSession.web.mentionCurrentWorkspace",
                defaultValue: "Current workspace"
            ),
            "skillMenuTitle": String(
                localized: "agentSession.web.skillMenuTitle",
                defaultValue: "Skills"
            ),
            "composerNoResults": String(
                localized: "agentSession.web.composerNoResults",
                defaultValue: "No results"
            ),
            "planMode": String(localized: "agentSession.web.planMode", defaultValue: "Plan mode"),
            "planSuggestionAction": String(
                localized: "agentSession.web.planSuggestion.action",
                defaultValue: "Use plan mode"
            ),
            "planSuggestionDismiss": String(
                localized: "agentSession.web.planSuggestion.dismiss",
                defaultValue: "Dismiss suggestion"
            ),
            "planSuggestionShortcut": String(
                localized: "agentSession.web.planSuggestion.shortcut",
                defaultValue: "Shift + Tab"
            ),
            "planSuggestionTitle": String(
                localized: "agentSession.web.planSuggestion.title",
                defaultValue: "Create a plan"
            ),
            "skillPlan": String(localized: "agentSession.web.skillPlan", defaultValue: "Plan"),
            "skillCodeReview": String(
                localized: "agentSession.web.skillCodeReview",
                defaultValue: "Code review"
            ),
            "skillResearch": String(
                localized: "agentSession.web.skillResearch",
                defaultValue: "Research"
            ),
            "loadingStatus": String(localized: "agentSession.web.status.loading", defaultValue: "Loading"),
            "idleStatus": String(localized: "agentSession.web.status.idle", defaultValue: "Idle"),
            "startingStatus": String(localized: "agentSession.web.status.starting", defaultValue: "Starting"),
            "runningStatus": String(localized: "agentSession.web.status.running", defaultValue: "Running"),
            "stoppingStatus": String(localized: "agentSession.web.status.stopping", defaultValue: "Stopping"),
            "failedStatus": String(localized: "agentSession.web.status.failed", defaultValue: "Failed"),
            "rendererReadyFormat": String(
                localized: "agentSession.web.log.rendererReadyFormat",
                defaultValue: "%@ ready"
            ),
            "stopped": String(localized: "agentSession.web.log.stopped", defaultValue: "Stopped"),
            "sentCharsFormat": String(
                localized: "agentSession.web.log.sentCharsFormat",
                defaultValue: "Sent %d chars"
            ),
            "providerStarted": String(
                localized: "agentSession.web.log.providerStarted",
                defaultValue: "Provider started"
            ),
            "providerExitedFormat": String(
                localized: "agentSession.web.log.providerExitedFormat",
                defaultValue: "Provider exited %d"
            ),
            "requestFailed": String(
                localized: "agentSession.web.error.requestFailed",
                defaultValue: "Native bridge request failed."
            )
        ])
    }
}
