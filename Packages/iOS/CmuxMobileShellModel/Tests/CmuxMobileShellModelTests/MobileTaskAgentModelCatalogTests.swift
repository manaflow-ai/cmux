import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskAgentModelCatalogTests {
    @Test(
        arguments: [
            ("claude -- \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.claude),
            ("codex -- \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.codex),
            ("opencode --prompt \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.openCode),
            ("/usr/local/bin/claude -- \"$CMUX_TASK_PROMPT\"", MobileTaskAgentProvider.claude),
        ]
    )
    func detectsProvider(command: String, expected: MobileTaskAgentProvider) {
        #expect(MobileTaskAgentModelCatalog.provider(forCommand: command) == expected)
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
        #expect(MobileTaskAgentModelCatalog.provider(forCommand: command) == nil)
    }

    @Test func codexModelsStartWithLuna() {
        #expect(
            MobileTaskAgentModelCatalog.models(for: .codex) == [
                MobileTaskAgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
                MobileTaskAgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                MobileTaskAgentModel(id: "gpt-5.5", displayName: "GPT-5.5"),
            ]
        )
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
        #expect(
            MobileTaskAgentModelCatalog.commandApplying(modelID: modelID, to: command)
                == expected
        )
    }

    @Test func nilModelKeepsCommandIdentical() {
        let command = " \nclaude -- \"$CMUX_TASK_PROMPT\"\n"
        #expect(MobileTaskAgentModelCatalog.commandApplying(modelID: nil, to: command) == command)
    }

    @Test func unknownProviderKeepsCommandIdentical() {
        let command = "custom-agent -- \"$CMUX_TASK_PROMPT\""
        #expect(
            MobileTaskAgentModelCatalog.commandApplying(modelID: "a-model", to: command)
                == command
        )
    }

    @Test func singleQuoteInModelIdentifierIsShellEscaped() {
        #expect(
            MobileTaskAgentModelCatalog.commandApplying(modelID: "one'two", to: "claude")
                == "claude --model 'one'\\''two'"
        )
    }

    @Test func preservesRestOfMultilineCommandByteForByte() {
        let command = "claude\t-- \"$CMUX_TASK_PROMPT\"\n  printf 'done'  \n"
        #expect(
            MobileTaskAgentModelCatalog.commandApplying(
                modelID: "claude-sonnet-5",
                to: command
            ) == "claude --model 'claude-sonnet-5'\t-- \"$CMUX_TASK_PROMPT\"\n  printf 'done'  \n"
        )
    }
}
