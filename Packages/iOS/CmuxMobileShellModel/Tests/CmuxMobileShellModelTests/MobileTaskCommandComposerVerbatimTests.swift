import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskCommandComposerVerbatimTests {
    private let composer = MobileTaskCommandComposer()

    @Test func arbitraryShellSourceIsNeverParsedOrRewritten() {
        let commands = [
            "echo {prompt}; printf %s {prompt}",
            "# don't parse {prompt}\nagent '$CMUX_TASK_PROMPT'",
            "cat <<'EOF'\n{prompt}\nEOF",
            "cat <<EOF\n$CMUX_TASK_PROMPT\nEOF",
            "result=\"$(agent {prompt})\"",
            "value=$((1 << 2))\nagent {prompt}",
            "result=\"`agent {prompt}`\"",
            "result=\"$(case x in x) agent {prompt} ;; esac)\"",
            "agent \\\n# {prompt}",
            "2>&1",
            "agent $$CMUX_TASK_PROMPT",
            "cat <<''\n{prompt}\n\n",
            "cat <<\"\"\n{prompt}\n\n",
            "if true; then\nagent {prompt}\nfi",
            "prepare && agent || recover",
            "agent # $CMUX_TASK_PROMPT and {prompt} are documentation",
            "agent \\$CMUX_TASK_PROMPT",
            "agent \"${#CMUX_TASK_PROMPT}\"",
            "agent \"${CMUX_TASK_PROMPT_EXTRA:-fallback}\"",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Custom", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "  space * ' quote  ")

            #expect(!template.isPlainShell)
            #expect(result.initialCommand == command)
            #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "space * ' quote"])
        }
    }

    @Test func nonblankCommentsAssignmentsAndRedirectionsRemainCommands() {
        let commands = [
            "# setup note",
            "FOO=bar # setup note",
            "> /tmp/cmux-task-output",
            "2>>/tmp/cmux-task-log",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Custom", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")

            #expect(!template.isPlainShell)
            #expect(result.initialCommand == command)
            #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
        }
    }
}
