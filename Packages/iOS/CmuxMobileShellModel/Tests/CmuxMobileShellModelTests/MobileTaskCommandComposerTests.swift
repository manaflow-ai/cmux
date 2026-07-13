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

    @Test func whitespaceOnlyCommandCreatesPlainShellForNonblankPrompt() {
        let template = MobileTaskTemplate(name: "Shell", icon: "terminal", command: " \n\t ")

        let result = composer.compose(template: template, prompt: "Investigate logs")

        #expect(result.initialCommand == nil)
        #expect(result.initialEnv.isEmpty)
        #expect(result.title == "Investigate logs")
    }

    @Test func whitespaceOnlyCommandCreatesPlainShellForBlankPrompt() {
        let template = MobileTaskTemplate(name: "Shell", icon: "terminal", command: " \n\t ")

        let result = composer.compose(template: template, prompt: " \n ")

        #expect(result.initialCommand == nil)
        #expect(result.initialEnv.isEmpty)
        #expect(result.title == nil)
    }

    @Test func appendModeAddsOptionTerminatorAndQuotedPromptArgument() {
        let template = MobileTaskTemplate(name: "Claude", icon: "brain.head.profile", command: "claude")

        let result = composer.compose(template: template, prompt: "fix 'quote'")

        #expect(result.initialCommand == "claude -- \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "fix 'quote'"])
    }

    @Test func appendModeTrimsTrailingNewlineBeforePromptArgument() {
        let template = MobileTaskTemplate(
            name: "Script",
            icon: "terminal",
            command: "printf ready\nagent\n"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "printf ready\nagent -- \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func appendModeTrimsTrailingSpacesBeforePromptArgument() {
        let template = MobileTaskTemplate(name: "Agent", icon: "terminal", command: "agent   ")

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent -- \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func appendModeCannotInterpretLeadingDashPromptAsAnOption() {
        let template = MobileTaskTemplate(name: "Agent", icon: "terminal", command: "agent")

        let result = composer.compose(template: template, prompt: "--dangerous-option")

        #expect(result.initialCommand == "agent -- \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "--dangerous-option"])
    }

    @Test func claudeAndCodexSeedsUseSafeImplicitAppendWhileOpenCodeKeepsExplicitPlaceholder() throws {
        let seeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Claude",
            codexName: "Codex",
            openCodeName: "OpenCode",
            shellName: "Shell"
        )
        let byName = Dictionary(uniqueKeysWithValues: seeds.map { ($0.name, $0) })

        #expect(composer.compose(template: try #require(byName["Claude"]), prompt: "--resume").initialCommand
            == "claude -- \"${CMUX_TASK_PROMPT}\"")
        #expect(composer.compose(template: try #require(byName["Codex"]), prompt: "--resume").initialCommand
            == "codex -- \"${CMUX_TASK_PROMPT}\"")
        #expect(composer.compose(template: try #require(byName["OpenCode"]), prompt: "--resume").initialCommand
            == "opencode --prompt \"${CMUX_TASK_PROMPT}\"")
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

    @Test func apostropheInCommentDoesNotChangeFollowingLineQuoteContext() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "# don't expand here\nclaude {prompt}"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "# don't expand here\nclaude \"${CMUX_TASK_PROMPT}\"")
    }

    @Test func placeholdersAndQuotesInsideCommentsRemainLiteralUntilNewline() {
        let template = MobileTaskTemplate(
            name: "Comments",
            icon: "terminal",
            command: "# '{prompt} \"ignored\"\nclaude {prompt}\n# \"{prompt}\"\ncodex {prompt}"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(
            result.initialCommand
                == "# '{prompt} \"ignored\"\nclaude \"${CMUX_TASK_PROMPT}\"\n# \"{prompt}\"\ncodex \"${CMUX_TASK_PROMPT}\""
        )
    }

    @Test func escapedEmbeddedAndQuotedHashesDoNotStartComments() {
        let commands = [
            "echo \\# {prompt}",
            "echo word#suffix {prompt}",
            "echo '#' {prompt}",
            "echo \"#\" {prompt}",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Hash", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")
            #expect(result.initialCommand?.hasSuffix("\"${CMUX_TASK_PROMPT}\"") == true)
        }
    }

    @Test func commentStartsAtControlOperatorWordBoundary() {
        let template = MobileTaskTemplate(
            name: "Boundary",
            icon: "terminal",
            command: "echo ready; # {prompt}\nclaude {prompt}"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "echo ready; # {prompt}\nclaude \"${CMUX_TASK_PROMPT}\"")
    }

    @Test func implicitAppendInsertsBeforeTrailingCommentLine() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "agent\n# keep this note\n"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent -- \"${CMUX_TASK_PROMPT}\"\n# keep this note\n")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func implicitAppendInsertsBeforeInlineTrailingComment() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "agent # keep this note"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent -- \"${CMUX_TASK_PROMPT}\" # keep this note")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func promptTokensInsideTrailingCommentDoNotSwallowFallbackArgument() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "agent\n# {prompt} and $CMUX_TASK_PROMPT stay documentation"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(
            result.initialCommand
                == "agent -- \"${CMUX_TASK_PROMPT}\"\n# {prompt} and $CMUX_TASK_PROMPT stay documentation"
        )
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func implicitAppendKeepsQuotedEscapedAndEmbeddedHashesAsTokens() {
        let commands = [
            "agent '#'",
            "agent \"#\"",
            "agent \\#",
            "agent word#suffix",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Hash", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")
            #expect(result.initialCommand == command + " -- \"${CMUX_TASK_PROMPT}\"")
        }
    }

    @Test func implicitAppendInsertsBeforeTrailingSemicolonAndComment() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "agent; # keep this note"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent -- \"${CMUX_TASK_PROMPT}\"; # keep this note")
    }

    @Test func implicitAppendInsertsBeforeTrailingBackgroundOperatorAndComment() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "agent & # keep this note"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent -- \"${CMUX_TASK_PROMPT}\" & # keep this note")
    }

    @Test func implicitAppendKeepsQuotedAndEscapedControlCharactersAsTokens() {
        let commands = [
            "agent ';'",
            "agent \"&\"",
            "agent \\)",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Operator", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")
            #expect(result.initialCommand == command + " -- \"${CMUX_TASK_PROMPT}\"")
        }
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

    @Test func blankPromptStillDefinesExplicitUnbracedEnvironmentReference() {
        let template = MobileTaskTemplate(
            name: "Custom",
            icon: "terminal",
            command: "agent \"$CMUX_TASK_PROMPT\""
        )

        let result = composer.compose(template: template, prompt: " \n ")

        #expect(result.initialCommand == "agent \"$CMUX_TASK_PROMPT\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": ""])
        #expect(result.title == nil)
    }

    @Test func blankPromptStillDefinesExplicitBracedEnvironmentReference() {
        let template = MobileTaskTemplate(
            name: "Custom",
            icon: "terminal",
            command: "agent \"${CMUX_TASK_PROMPT}\""
        )

        let result = composer.compose(template: template, prompt: " \n ")

        #expect(result.initialCommand == "agent \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": ""])
        #expect(result.title == nil)
    }

    @Test func promptEnvironmentReferenceInsideCommentDoesNotSuppressImplicitArgument() {
        let template = MobileTaskTemplate(
            name: "Comment",
            icon: "terminal",
            command: "# $CMUX_TASK_PROMPT is documented here\nagent"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "# $CMUX_TASK_PROMPT is documented here\nagent -- \"${CMUX_TASK_PROMPT}\"")
    }

    @Test func singleQuotedPromptEnvironmentTextDoesNotSuppressImplicitArgument() {
        let template = MobileTaskTemplate(
            name: "Literal",
            icon: "terminal",
            command: "agent '$CMUX_TASK_PROMPT'"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent '$CMUX_TASK_PROMPT' -- \"${CMUX_TASK_PROMPT}\"")
    }

    @Test func escapedPromptEnvironmentTextDoesNotSuppressImplicitArgument() {
        let template = MobileTaskTemplate(
            name: "Escaped",
            icon: "terminal",
            command: "agent \\$CMUX_TASK_PROMPT"
        )

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "agent \\$CMUX_TASK_PROMPT -- \"${CMUX_TASK_PROMPT}\"")
    }

    @Test func submissionIdentityStaysStableUntilRotated() {
        let restoredID = UUID()
        var identity = MobileTaskSubmissionIdentity(id: restoredID)

        #expect(identity.id == restoredID)
        #expect(identity.id == restoredID)

        identity.rotate()

        #expect(identity.id != restoredID)
    }

    @Test func submissionSnapshotKeepsSentValuesForSuccessAndFailureSettlement() {
        let operationID = UUID()
        let templateID = UUID()
        let template = MobileTaskTemplate(
            id: templateID,
            name: "Codex",
            icon: "sparkles",
            command: "codex {prompt}"
        )
        let snapshot = MobileTaskSubmissionSnapshot(
            template: template,
            prompt: "Fix the race",
            macDeviceID: "mac-a",
            directory: "  ~/cmux  ",
            didEditDirectory: true,
            operationID: operationID
        )

        #expect(snapshot.templateID == template.id)
        #expect(snapshot.macDeviceID == "mac-a")
        #expect(snapshot.trimmedDirectory == "~/cmux")
        #expect(snapshot.operationID == operationID)
        #expect(snapshot.composition.initialCommand == "codex \"${CMUX_TASK_PROMPT}\"")
        #expect(snapshot.draft == MobileTaskComposerDraft(
            prompt: "Fix the race",
            templateID: template.id,
            macDeviceID: "mac-a",
            directory: "  ~/cmux  ",
            didEditDirectory: true,
            operationID: operationID
        ))
    }

    @Test func titleUsesFirstTrimmedLineAndTruncatesToSixtyCharacters() {
        let template = MobileTaskTemplate(name: "Codex", icon: "sparkles", command: "codex")
        let prompt = "  123456789012345678901234567890123456789012345678901234567890abcdef\nsecond line  "

        let result = composer.compose(template: template, prompt: prompt)

        #expect(result.title == "123456789012345678901234567890123456789012345678901234567890")
    }
}
