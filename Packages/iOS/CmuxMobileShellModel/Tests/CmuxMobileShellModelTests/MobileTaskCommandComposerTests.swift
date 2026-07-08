import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskCommandComposerTests {
    private let composer = MobileTaskCommandComposer()

    @Test func shellQuotedEscapesSingleQuotesNewlinesAndEmoji() {
        #expect(composer.shellQuoted("fix Bob's\nemoji 😀") == "'fix Bob'\\''s\nemoji 😀'")
    }

    @Test func placeholderReplacesEveryOccurrence() {
        let template = MobileTaskTemplate(name: "Echo", icon: "terminal", command: "echo {prompt}; printf %s {prompt}")

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "echo 'ship it'; printf %s 'ship it'")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func emptyPromptWithPlaceholderUsesEmptyQuotedArgument() {
        let template = MobileTaskTemplate(name: "Echo", icon: "terminal", command: "echo {prompt}")

        let result = composer.compose(template: template, prompt: " \n ")

        #expect(result.initialCommand == "echo ''")
        #expect(result.initialEnv.isEmpty)
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

        #expect(result.initialCommand == "claude 'fix '\\''quote'\\'''")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "fix 'quote'"])
    }

    @Test func appendModeLeavesCommandUnchangedForEmptyPrompt() {
        let template = MobileTaskTemplate(name: "Codex", icon: "sparkles", command: "codex")

        let result = composer.compose(template: template, prompt: "")

        #expect(result.initialCommand == "codex")
        #expect(result.initialEnv.isEmpty)
        #expect(result.title == nil)
    }

    @Test func titleUsesFirstTrimmedLineAndTruncatesToSixtyCharacters() {
        let template = MobileTaskTemplate(name: "Codex", icon: "sparkles", command: "codex")
        let prompt = "  123456789012345678901234567890123456789012345678901234567890abcdef\nsecond line  "

        let result = composer.compose(template: template, prompt: prompt)

        #expect(result.title == "123456789012345678901234567890123456789012345678901234567890")
    }
}
