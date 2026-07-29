import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskAgentProviderTests {
    @Test(
        arguments: [
            ("claude -- \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.claude),
            ("codex -- \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.codex),
            ("opencode --prompt \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.openCode),
            ("/usr/local/bin/claude -- \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.claude),
        ]
    )
    func detectsProvider(command: String, expected: MobileTaskAgentProvider) {
        #expect(MobileTaskAgentProvider(command: command) == expected)
    }

    @Test(
        arguments: [
            "cd x && claude -- \"$CMUX_TASK_PROMPT\"",
            "FOO=1 claude -- \"$CMUX_TASK_PROMPT\"",
            "claudex -- \"$CMUX_TASK_PROMPT\"",
            "",
            " \n\t ",
        ]
    )
    func rejectsUnsupportedProvider(command: String) {
        #expect(MobileTaskAgentProvider(command: command) == nil)
    }

    @Test func codexModelsStartWithLuna() {
        #expect(
            MobileTaskAgentProvider.codex.models == [
                MobileTaskAgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
                MobileTaskAgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                MobileTaskAgentModel(id: "gpt-5.5", displayName: "GPT-5.5"),
            ]
        )
    }

    @Test func validatesCuratedModelIdentifier() {
        #expect(MobileTaskAgentProvider.claude.model(id: "claude-opus-4-8")?.displayName == "Opus 4.8")
        #expect(MobileTaskAgentProvider.claude.model(id: "gpt-5.5") == nil)
    }

    @Test(
        arguments: [
            (
                "claude -- \"$CMUX_TASK_PROMPT\"",
                "claude-opus-4-8",
                "claude --model 'claude-opus-4-8' -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                "codex -- \"$CMUX_TASK_PROMPT\"",
                "gpt-5.5",
                "codex -m 'gpt-5.5' -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                "opencode --prompt \"$CMUX_TASK_PROMPT\"",
                "anthropic/claude-sonnet-5",
                "opencode --model 'anthropic/claude-sonnet-5' --prompt \"$CMUX_TASK_PROMPT\""
            ),
        ]
    )
    func appliesProviderFlag(command: String, modelID: String, expected: String) {
        let provider = MobileTaskAgentProvider(command: command)
        #expect(provider?.command(applying: modelID, to: command) == expected)
    }

    @Test func singleQuoteInModelIdentifierIsShellEscaped() {
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "one'two", to: "claude")
                == "claude --model 'one'\\''two'"
        )
    }

    @Test func preservesRestOfMultilineCommandByteForByte() {
        let command = "claude\t-- \"$CMUX_TASK_PROMPT\"\n  printf 'done'  \n"
        #expect(
            MobileTaskAgentProvider.claude.command(
                applying: "claude-sonnet-5",
                to: command
            ) == "claude --model 'claude-sonnet-5'\t-- \"$CMUX_TASK_PROMPT\"\n  printf 'done'  \n"
        )
    }

    @Test(
        arguments: [
            (
                "claude --model claude-sonnet-4-5 --verbose -- \"$CMUX_TASK_PROMPT\"",
                "claude-opus-4-8",
                "claude --model 'claude-opus-4-8' --verbose -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                "codex -m old-model -- \"$CMUX_TASK_PROMPT\"",
                "gpt-5.6-sol",
                "codex -m 'gpt-5.6-sol' -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                "codex --model old-model -- \"$CMUX_TASK_PROMPT\"",
                "gpt-5.6-sol",
                "codex --model 'gpt-5.6-sol' -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                "claude --model=claude-sonnet-4-5 -- \"$CMUX_TASK_PROMPT\"",
                "claude-opus-4-8",
                "claude --model='claude-opus-4-8' -- \"$CMUX_TASK_PROMPT\""
            ),
        ]
    )
    func replacesExistingModelFlagValue(command: String, modelID: String, expected: String) {
        let provider = MobileTaskAgentProvider(command: command)
        #expect(provider?.command(applying: modelID, to: command) == expected)
    }

    @Test func appendsValueForDanglingModelFlag() {
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "claude-opus-4-8", to: "claude --model")
                == "claude --model 'claude-opus-4-8'"
        )
    }

    @Test func ignoresModelFlagAfterEndOfOptions() {
        let command = "claude -- --model literal-arg"
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "claude-opus-4-8", to: command)
                == "claude --model 'claude-opus-4-8' -- --model literal-arg"
        )
    }

    @Test func claudeDoesNotTreatShortMAsModelFlag() {
        let command = "claude -m other -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "claude-opus-4-8", to: command)
                == "claude --model 'claude-opus-4-8' -m other -- \"$CMUX_TASK_PROMPT\""
        )
    }

    @Test func flagTextInsideQuotedArgumentIsNotRewritten() {
        let command = "claude --append-system-prompt \"Never pass --model manually\" -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "claude-opus-4-8", to: command)
                == "claude --model 'claude-opus-4-8' --append-system-prompt \"Never pass --model manually\" -- \"$CMUX_TASK_PROMPT\""
        )
    }

    @Test func flagTextInsideSingleQuotedArgumentIsNotRewritten() {
        let command = "codex --note 'use -m sparingly' -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentProvider.codex.command(applying: "gpt-5.5", to: command)
                == "codex -m 'gpt-5.5' --note 'use -m sparingly' -- \"$CMUX_TASK_PROMPT\""
        )
    }

    @Test func replacesEveryModelFlagBeforeEndOfOptions() {
        let command = "codex -m first --model second -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentProvider.codex.command(applying: "gpt-5.6-sol", to: command)
                == "codex -m 'gpt-5.6-sol' --model 'gpt-5.6-sol' -- \"$CMUX_TASK_PROMPT\""
        )
    }

    @Test func suppliesValueWhenFlagSitsDirectlyBeforeEndOfOptions() {
        let command = "claude --model -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "claude-opus-4-8", to: command)
                == "claude --model 'claude-opus-4-8' -- \"$CMUX_TASK_PROMPT\""
        )
    }

    @Test func replacesQuotedFlagValueAsOneToken() {
        let command = "claude --model \"old model\" -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentProvider.claude.command(applying: "claude-opus-4-8", to: command)
                == "claude --model 'claude-opus-4-8' -- \"$CMUX_TASK_PROMPT\""
        )
    }
}
