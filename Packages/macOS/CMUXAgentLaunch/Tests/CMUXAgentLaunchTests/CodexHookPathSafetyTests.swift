import CMUXAgentLaunch
import Testing

@Suite("Codex hook path safety")
struct CodexHookPathSafetyTests {
    @Test("Strips shell-quoted content-addressed hooks below a shell-significant home path")
    func stripsShellQuotedContentAddressedHooksBelowShellSignificantHomePath() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            let path = "/Volumes/Home Disk/Example $HOME/O'Reilly/.cmux/hooks/cmux-codex-hook-0123456789abcdef-\(subcommand).sh"
            return "'\(path.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips canonical quoted hooks with boundary whitespace in path components")
    func stripsCanonicalQuotedHooksWithBoundaryWhitespaceInPathComponents() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            let path = "/Volumes/ Home /Example $HOME/O'Reilly/.cmux/hooks/cmux-codex-hook-0123456789abcdef-\(subcommand).sh"
            return CodexHookScriptName.shellCommand(forScriptPath: path)
        } + ["--model", "gpt-5.5"]

        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Preserves legacy bare hook paths with control characters")
    func preservesLegacyBareHookPathsWithControlCharacters() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            "/Users/Example\nName/.cmux/hooks/cmux-codex-hook-0123456789abcdef-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]

        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == arguments
        )
    }

    @Test("Preserves legacy bare hook paths with shell metacharacters")
    func preservesLegacyBareHookPathsWithShellMetacharacters() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            "/Users/Example;Name/.cmux/hooks/cmux-codex-hook-0123456789abcdef-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]

        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == arguments
        )
    }

    private func codexWrapperHookArguments(
        joined: Bool = false,
        command: (String) -> String
    ) -> [String] {
        var arguments = joined
            ? ["--enable=hooks", "--dangerously-bypass-hook-trust"]
            : ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
        for (index, event) in CodexHookInjectionSchema.current.events.enumerated() {
            let value = "hooks.\(event.agentEvent)=[{hooks=[{type=\"command\",command='''\(command(event.cmuxSubcommand))''',timeout=\(event.timeoutMs)}]}]"
            let option = index.isMultiple(of: 2) ? "-c" : "--config"
            if joined {
                arguments.append("\(option)=\(value)")
            } else {
                arguments.append(contentsOf: [option, value])
            }
        }
        return arguments
    }
}
