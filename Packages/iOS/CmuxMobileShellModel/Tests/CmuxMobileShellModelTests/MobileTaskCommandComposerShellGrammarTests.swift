import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskCommandComposerShellGrammarTests {
    private let composer = MobileTaskCommandComposer()

    @Test func noCommandTemplatesOpenPlainShellForBlankAndNonblankPrompts() {
        let commands = [
            "# setup note",
            " \t# setup note\n",
            "# first note\n  # second note  ",
            "FOO=bar # setup note",
            "FOO='bar baz'\n# setup note",
            "> /tmp/cmux-task-output # setup note",
            "2>>/tmp/cmux-task-log\n# setup note",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Notes", icon: "terminal", command: command)
            #expect(template.isPlainShell)

            let prompted = composer.compose(template: template, prompt: "ship it")
            #expect(prompted.initialCommand == nil)
            #expect(prompted.initialEnv.isEmpty)
            #expect(prompted.title == "ship it")

            let blank = composer.compose(template: template, prompt: " \n ")
            #expect(blank.initialCommand == nil)
            #expect(blank.initialEnv.isEmpty)
            #expect(blank.title == nil)
        }
    }

    @Test func commandsRemainExecutableAfterLeadingAssignmentsAndRedirections() {
        let commands = [
            "FOO=bar agent",
            "> /tmp/cmux-task-output agent",
            "FOO='bar baz' 2>>/tmp/cmux-task-log agent",
            "agent > /tmp/cmux-task-output",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Agent", icon: "terminal", command: command)
            #expect(!template.isPlainShell)
            #expect(composer.compose(template: template, prompt: "").initialCommand == command)
        }
    }

    @Test func unsupportedShellGrammarDeclinesImplicitPromptInjection() {
        let commands = [
            "cat <<'EOF'\ncontext\nEOF",
            "agent <<< context",
            "if true; then\nagent\nfi",
            "for item in one two; do\nagent\ndone",
            "(agent)",
            "{ agent; }",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Script", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")
            #expect(!template.isPlainShell)
            #expect(result.initialCommand == command)
            #expect(result.initialEnv.isEmpty)
            #expect(result.title == "ship it")
        }
    }

    @Test func unsupportedShellGrammarKeepsExplicitPromptConsumers() {
        let placeholder = MobileTaskTemplate(
            name: "Script",
            icon: "terminal",
            command: "if true; then\nagent {prompt}\nfi"
        )
        let environment = MobileTaskTemplate(
            name: "Script",
            icon: "terminal",
            command: "if true; then\nagent \"$CMUX_TASK_PROMPT\"\nfi"
        )

        let placeholderResult = composer.compose(template: placeholder, prompt: "ship it")
        let environmentResult = composer.compose(template: environment, prompt: "ship it")
        #expect(placeholderResult.initialCommand == "if true; then\nagent \"${CMUX_TASK_PROMPT}\"\nfi")
        #expect(environmentResult.initialCommand == environment.command)
        #expect(placeholderResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
        #expect(environmentResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func heredocBodiesKeepPromptPlaceholdersLiteral() {
        let commands = [
            "cat <<'EOF'\n{prompt}\nEOF",
            "cat <<EOF\n{prompt}\nEOF",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Script", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")

            #expect(result.initialCommand == command)
            #expect(result.initialEnv.isEmpty)
        }
    }

    @Test func heredocEnvironmentReferenceHonorsDelimiterExpansion() {
        let expandable = "cat <<EOF\n$CMUX_TASK_PROMPT\nEOF"
        let literal = "cat <<'EOF'\n$CMUX_TASK_PROMPT\nEOF"

        let expandableResult = composer.compose(
            template: MobileTaskTemplate(name: "Script", icon: "terminal", command: expandable),
            prompt: "ship it"
        )
        let literalResult = composer.compose(
            template: MobileTaskTemplate(name: "Script", icon: "terminal", command: literal),
            prompt: "ship it"
        )

        #expect(expandableResult.initialCommand == expandable)
        #expect(expandableResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
        #expect(literalResult.initialCommand == literal)
        #expect(literalResult.initialEnv.isEmpty)
    }

    @Test func heredocLiteralRangeEndsAtItsTerminator() {
        let command = "cat <<EOF\n{prompt}\nEOF\nagent {prompt}"
        let template = MobileTaskTemplate(name: "Script", icon: "terminal", command: command)

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == "cat <<EOF\n{prompt}\nEOF\nagent \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func compoundCommandsRequireExplicitPromptConsumer() {
        let commands = [
            "claude | tee /tmp/task.log",
            "prepare && claude",
            "prepare || recover",
            "prepare; claude",
            "prepare\nclaude",
            "prepare & wait",
        ]

        for command in commands {
            let template = MobileTaskTemplate(name: "Compound", icon: "terminal", command: command)
            let result = composer.compose(template: template, prompt: "ship it")
            #expect(result.initialCommand == command)
            #expect(result.initialEnv.isEmpty)
            #expect(result.title == "ship it")
        }
    }

    @Test func compoundCommandsKeepExplicitPromptConsumers() {
        let placeholder = MobileTaskTemplate(
            name: "Pipeline",
            icon: "terminal",
            command: "claude {prompt} | tee /tmp/task.log"
        )
        let environment = MobileTaskTemplate(
            name: "Pipeline",
            icon: "terminal",
            command: "claude \"$CMUX_TASK_PROMPT\" | tee /tmp/task.log"
        )

        let placeholderResult = composer.compose(template: placeholder, prompt: "ship it")
        let environmentResult = composer.compose(template: environment, prompt: "ship it")
        #expect(placeholderResult.initialCommand == "claude \"${CMUX_TASK_PROMPT}\" | tee /tmp/task.log")
        #expect(environmentResult.initialCommand == environment.command)
        #expect(placeholderResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
        #expect(environmentResult.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }

    @Test func reservedWordsRemainArgumentsAfterARealCommandWord() {
        let command = "agent if then fi done esac"
        let template = MobileTaskTemplate(name: "Agent", icon: "terminal", command: command)

        let result = composer.compose(template: template, prompt: "ship it")

        #expect(result.initialCommand == command + " -- \"${CMUX_TASK_PROMPT}\"")
        #expect(result.initialEnv == ["CMUX_TASK_PROMPT": "ship it"])
    }
}
