import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskCommandComposerTests {
    private let composer = MobileTaskCommandComposer()

    @Test func placeholderReplacesEveryOccurrence() {
        let template = MobileTaskTemplate(name: "Echo", icon: "terminal", command: "echo {prompt}; printf %s {prompt}")

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "echo \"${CMUX_TASK_PROMPT}\"; printf %s \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func emptyPromptWithPlaceholderUsesEmptyQuotedArgument() {
        let template = MobileTaskTemplate(name: "Echo", icon: "terminal", command: "echo {prompt}")

        let result = composer.compose(template: template, prompt: " \n ")

        #expect(result.initialCommand == "echo \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": ""])
        #expect(result.title == nil)
    }

    @Test func emptyCommandCreatesPlainShellButStillDerivesTitle() {
        let template = MobileTaskTemplate(name: "Shell", icon: "terminal", command: "")

        let result = composer.compose(template: template, prompt: "Investigate logs")

        #expect(result.initialCommand == nil)
        #expect(result.initialEnv.isEmpty)
        #expect(result.title == "Investigate logs")
    }

    @Test func appendModeAddsQuotedPromptArgument() {
        let template = MobileTaskTemplate(name: "Claude", icon: "brain.head.profile", command: "claude")

        let result = composer.compose(template: template, prompt: "fix 'quote'")

        #expect(result.initialCommand == "claude \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "fix 'quote'"])
    }

    @Test func placeholdersInsideShellQuotesCannotReparsePromptText() {
        let template = MobileTaskTemplate(
            name: "Quoted",
            icon: "terminal",
            command: "claude \"{prompt}\"; codex '{prompt}'; tool --prompt={prompt}"
        )
        let prompt = "$(touch /tmp/injected) `id` $HOME ' \""

        let result = composer.compose(template: template, prompt: prompt)

        #expect(
            result.initialCommand
                == "claude \"${CMUX_TASK_PROMPT}\"; codex ''\"${CMUX_TASK_PROMPT}\"''; tool --prompt=\"${CMUX_TASK_PROMPT}\""
        )
        #expect(result.initialCommand?.contains("touch") == false)
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": prompt])
    }

    @Test func appendModeLeavesCommandUnchangedForEmptyPrompt() {
        let template = MobileTaskTemplate(name: "Codex", icon: "sparkles", command: "codex")

        let result = composer.compose(template: template, prompt: "")

        #expect(result.initialCommand == "codex")
        #expect(result.initialEnv.isEmpty)
        #expect(result.title == nil)
    }

    @Test func documentedPromptEnvironmentConsumerDoesNotReceiveDuplicateArgument() {
        let unbracedTemplate = MobileTaskTemplate(
            name: "Custom",
            icon: "terminal",
            command: "agent \"$CMUX_TASK_PROMPT\""
        )
        let bracedTemplate = MobileTaskTemplate(
            name: "Custom",
            icon: "terminal",
            command: "agent \"${CMUX_TASK_PROMPT}\""
        )

        let unbracedResult = composer.compose(template: unbracedTemplate, prompt: "ship it")
        let bracedResult = composer.compose(template: bracedTemplate, prompt: "ship it")

        #expect(unbracedResult.initialCommand == "agent \"$CMUX_TASK_PROMPT\"")
        #expect(bracedResult.initialCommand == "agent \"${CMUX_TASK_PROMPT}\"")
        #expect(unbracedResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
        #expect(bracedResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func submissionIdentityStaysStableUntilRotated() {
        let restoredID = UUID()
        var identity = MobileTaskSubmissionIdentity(id: restoredID)

        #expect(identity.id == restoredID)
        #expect(identity.id == restoredID)

        identity.rotate()

        #expect(identity.id != restoredID)
    }

    @Test func titleUsesFirstTrimmedLineAndTruncatesToSixtyCharacters() {
        let template = MobileTaskTemplate(name: "Codex", icon: "sparkles", command: "codex")
        let prompt = "  123456789012345678901234567890123456789012345678901234567890abcdef\nsecond line  "

        let result = composer.compose(template: template, prompt: prompt)

        #expect(result.title == "123456789012345678901234567890123456789012345678901234567890")
    }
}
