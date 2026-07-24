import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskCommandComposerTests {
    private let composer = MobileTaskCommandComposer()

    @Test func whitespaceOnlyCommandsCreatePlainShells() {
        for command in ["", " ", " \n\t "] {
            let template = MobileTaskTemplate(name: "Shell", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "Investigate logs")

            #expect(template.isPlainShell)
            #expect(result.initialCommand == nil)
            #expect(result.initialEnv.isEmpty)
            #expect(result.title == "Investigate logs")
        }
    }

    @Test func nonblankCommandAndBlankPromptRemainExplicit() {
        let command = "codex -- \"$CMUX_TASK_PROMPT\""
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: command)

        let result = composer.compose(template: template, prompt: " \n ")

        #expect(!template.isPlainShell)
        #expect(result.initialCommand == command)
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": ""])
        #expect(result.title == nil)
    }

    @Test func promptIsTrimmedOnlyInEnvironmentAndTitle() {
        let command = "agent --flag"
        let template = MobileTaskTemplate(name: "Agent", icon: "terminal", command: command)

        let result = composer.compose(template: template, prompt: "  Fix the race  \n ")

        #expect(result.initialCommand == command)
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "Fix the race"])
        #expect(result.title == "Fix the race")
    }

    @Test func seededCommandsConsumeThePromptEnvironmentExplicitly() {
        let seeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Claude",
            codexName: "Codex",
            openCodeName: "OpenCode",
            shellName: "Shell"
        )

        #expect(seeds.map(\.command) == [
            "claude -- \"$CMUX_TASK_PROMPT\"",
            "codex -- \"$CMUX_TASK_PROMPT\"",
            "opencode --prompt \"$CMUX_TASK_PROMPT\"",
            "",
        ])
        for template in seeds.dropLast() {
            let result = composer.compose(template: template, prompt: "--resume")
            #expect(result.initialCommand == template.command)
            #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "--resume"])
        }
    }

    @Test func seededAgentCommandsApplySelectedModels() {
        let seeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Claude",
            codexName: "Codex",
            openCodeName: "OpenCode",
            shellName: "Shell"
        )
        let cases = [
            (
                seeds[0],
                "claude-opus-4-8",
                "claude --model 'claude-opus-4-8' -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                seeds[1],
                "gpt-5.5",
                "codex -m 'gpt-5.5' -- \"$CMUX_TASK_PROMPT\""
            ),
            (
                seeds[2],
                "openai/gpt-5.5",
                "opencode --model 'openai/gpt-5.5' --prompt \"$CMUX_TASK_PROMPT\""
            ),
        ]

        for (template, modelID, expectedCommand) in cases {
            let result = composer.compose(
                template: template,
                prompt: "  Fix the race  ",
                modelID: modelID
            )
            #expect(result.initialCommand == expectedCommand)
            #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "Fix the race"])
            #expect(result.title == "Fix the race")
        }
    }

    @Test func selectedModelKeepsPlainShellPlain() {
        let template = MobileTaskTemplate(name: "Shell", icon: "terminal", command: "")
        let result = composer.compose(
            template: template,
            prompt: "Run diagnostics",
            modelID: "gpt-5.5"
        )

        #expect(result.initialCommand == nil)
        #expect(result.initialEnv.isEmpty)
        #expect(result.title == "Run diagnostics")
    }

    @Test func selectedModelKeepsUnknownCommandVerbatim() {
        let command = "custom-agent -- \"$CMUX_TASK_PROMPT\""
        let template = MobileTaskTemplate(name: "Custom", icon: "terminal", command: command)
        let result = composer.compose(
            template: template,
            prompt: "Investigate",
            modelID: "gpt-5.5"
        )

        #expect(result.initialCommand == command)
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "Investigate"])
        #expect(result.title == "Investigate")
    }

    @Test func submissionIdentityStaysStableUntilRotated() {
        let restoredID = UUID()
        var identity = MobileTaskSubmissionIdentity(id: restoredID)

        #expect(identity.id == restoredID)
        #expect(identity.id == restoredID)

        identity.rotate()

        #expect(identity.id != restoredID)
    }

    @Test func submissionSnapshotKeepsTheVerbatimCommand() {
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
        #expect(snapshot.composition.initialCommand == "codex {prompt}")
        #expect(snapshot.composition.initialEnv == ["CMUX_TASK_PROMPT": "Fix the race"])
        #expect(snapshot.draft == MobileTaskComposerDraft(
            prompt: "Fix the race",
            modelID: nil,
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
