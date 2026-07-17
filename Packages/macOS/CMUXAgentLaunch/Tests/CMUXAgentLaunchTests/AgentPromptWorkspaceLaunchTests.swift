import CMUXAgentLaunch
import Testing

@Suite("AgentPromptWorkspaceLaunch")
struct AgentPromptWorkspaceLaunchTests {
    @Test("Shell command quotes executable and prompt")
    func shellCommandQuoting() {
        #expect(
            AgentPromptWorkspaceLaunch.shellCommand(
                executablePath: "/Users/dev/.bun/bin/claude",
                prompt: "fix the login bug"
            ) == "'/Users/dev/.bun/bin/claude' 'fix the login bug'"
        )
    }

    @Test("Embedded single quotes survive quoting")
    func singleQuoteEscaping() {
        #expect(
            AgentPromptWorkspaceLaunch.singleQuoted("don't panic") == "'don'\\''t panic'"
        )
    }

    @Test("Short single-line command types inline with trailing newline")
    func inlineStartupInput() {
        let command = "'/usr/local/bin/codex' 'add tests'"
        #expect(
            AgentPromptWorkspaceLaunch.startupInput(command: command)
                == .inline(command + "\n")
        )
    }

    @Test("Multiline prompt always routes through a launcher script")
    func multilineUsesScript() {
        let command = AgentPromptWorkspaceLaunch.shellCommand(
            executablePath: "/usr/local/bin/claude",
            prompt: "step one\nstep two"
        )
        #expect(
            AgentPromptWorkspaceLaunch.startupInput(command: command)
                == .script(body: "#!/bin/zsh\nexec \(command)\n")
        )
    }

    @Test("Oversized command routes through a launcher script")
    func oversizedUsesScript() {
        let command = AgentPromptWorkspaceLaunch.shellCommand(
            executablePath: "/usr/local/bin/claude",
            prompt: String(repeating: "a", count: 2000)
        )
        guard case .script(let body) = AgentPromptWorkspaceLaunch.startupInput(command: command) else {
            Issue.record("expected script fallback")
            return
        }
        #expect(body.hasPrefix("#!/bin/zsh\nexec "))
        #expect(body.hasSuffix("\n"))
    }

    @Test("Inline budget boundary is byte-exact")
    func inlineBudgetBoundary() {
        let boundaryCommand = String(repeating: "x", count: 899)
        #expect(
            AgentPromptWorkspaceLaunch.startupInput(command: boundaryCommand)
                == .inline(boundaryCommand + "\n")
        )
        let overCommand = String(repeating: "x", count: 900)
        #expect(
            AgentPromptWorkspaceLaunch.startupInput(command: overCommand)
                == .script(body: "#!/bin/zsh\nexec \(overCommand)\n")
        )
    }

    @Test("Script invocation quotes the path")
    func scriptInvocation() {
        #expect(
            AgentPromptWorkspaceLaunch.scriptInvocation(scriptPath: "/tmp/agent launch.zsh")
                == "/bin/zsh '/tmp/agent launch.zsh'\n"
        )
    }

    @Test("Title uses the first line with collapsed whitespace")
    func titleDerivation() {
        #expect(
            AgentPromptWorkspaceLaunch.derivedWorkspaceTitle(
                prompt: "  Fix   the flaky\ttest \nand more detail below"
            ) == "Fix the flaky test"
        )
    }

    @Test("Long titles cut at a word boundary with ellipsis")
    func titleWordBoundaryCut() {
        let title = AgentPromptWorkspaceLaunch.derivedWorkspaceTitle(
            prompt: "Refactor the workspace sidebar rendering pipeline to avoid livelocks"
        )
        #expect(title == "Refactor the workspace sidebar rendering…")
    }

    @Test("Blank prompt has no title")
    func blankTitle() {
        #expect(AgentPromptWorkspaceLaunch.derivedWorkspaceTitle(prompt: "  \n ") == nil)
    }
}
