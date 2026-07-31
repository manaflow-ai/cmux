import Testing
@testable import CMUXAgentLaunch

@Suite struct AgentRestoreLaunchTests {
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"

    @Test(arguments: ["claude", "codex"])
    func supportedProviderOwnsWrapperConfiguration(kind: String) throws {
        let launch = try #require(AgentRestoreLaunch(kind: " \(kind.uppercased()) ", sessionID: sessionID))

        #expect(launch.executableName == kind)
        #expect(launch.wrapperShellExecutableToken.contains("CMUX_\(kind.uppercased())_WRAPPER_SHIM"))
        #expect(launch.customExecutablePathEnvironmentKey == "CMUX_CUSTOM_\(kind.uppercased())_PATH")
        #expect(launch.portableWrapperShellCommand(posixCommand: "wrapper --resume").hasPrefix("/bin/sh -c "))
    }

    @Test func invalidOwnershipCannotCreateRestoreLaunch() {
        #expect(AgentRestoreLaunch(kind: "gemini", sessionID: sessionID) == nil)
        #expect(AgentRestoreLaunch(kind: "codex", sessionID: "not-a-session-id") == nil)
        #expect(AgentRestoreLaunch(kind: nil, sessionID: sessionID) == nil)
        #expect(AgentRestoreLaunch(kind: "claude", sessionID: nil) == nil)
    }

    @Test func authorizationUsesShellPortableEnvironmentTransport() throws {
        let launch = try #require(AgentRestoreLaunch(kind: "codex", sessionID: sessionID))

        #expect(
            launch.authorizing(
                leadingShell: "cd -- '/repo' && ",
                routedCommand: "/bin/sh -c 'wrapper resume'"
            ) == "cd -- '/repo' && /usr/bin/env 'CMUX_AGENT_RESTORE_LAUNCH=codex:\(sessionID)' /bin/sh -c 'wrapper resume'"
        )
    }

    @Test func bundledCLIStartupTokenQuotesAbsolutePathWithoutEnvironmentLookup() {
        #expect(
            AgentRestoreLaunch.bundledCLIStartupExecutableToken(
                bundledCLIPath: "/Applications/cmux user's build.app/Contents/Resources/bin/cmux"
            )
                == "'/Applications/cmux user'\\''s build.app/Contents/Resources/bin/cmux'"
        )
        #expect(
            AgentRestoreLaunch.bundledCLIStartupExecutableToken(
                bundledCLIPath: nil
            ) == "cmux"
        )
    }

    @Test func structuredCodexRestorePlansDirectArgvEnvironmentAndCwd() throws {
        let workingDirectory = "/tmp/项目 with 'quotes'"
        let capturedWorkingDirectory = "/tmp/old project"
        let launch = AgentLaunchCommand(
            launcher: nil,
            executablePath: "/opt/company bin/codex",
            arguments: [
                "/opt/company bin/codex",
                "--model",
                "gpt-5.6-sol",
                "-c",
                #"model_provider="subrouter""#,
                "--cd",
                capturedWorkingDirectory,
            ],
            workingDirectory: capturedWorkingDirectory,
            environment: ["CODEX_HOME": "/tmp/配置"],
            capturedAt: 1,
            source: "test"
        )
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: workingDirectory,
            environment: [:],
            launchCommand: launch,
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let planner = AgentRestorePlanner(isExecutableFile: { $0 == "/shim/codex" })
        let invocation = try #require(planner.invocation(
            for: request,
            ambientEnvironment: [
                "PATH": "/usr/bin:/bin",
                "CMUX_CODEX_WRAPPER_SHIM": "/shim/codex",
            ]
        ))

        #expect(invocation.workingDirectory == workingDirectory)
        #expect(invocation.arguments.first == "/shim/codex")
        #expect(invocation.arguments.dropFirst().starts(with: ["resume", sessionID]))
        #expect(invocation.arguments.contains("check_for_update_on_startup=false"))
        #expect(invocation.arguments.contains(#"model_provider="subrouter""#))
        #expect(invocation.arguments.contains(capturedWorkingDirectory) == false)
        #expect(invocation.environment["CODEX_HOME"] == "/tmp/配置")
        #expect(invocation.environment["CMUX_CUSTOM_CODEX_PATH"] == "/opt/company bin/codex")
        #expect(
            invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"]
                == "codex:\(sessionID)"
        )
        #expect(invocation.arguments.contains("/bin/sh") == false)
        #expect(invocation.arguments.contains("-lc") == false)
    }

    @Test func structuredClaudeRestoreAppliesObservedPermissionModeWithoutParsingShell() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: nil,
                executablePath: "/opt/claude",
                arguments: ["/opt/claude", "--model", "sonnet"],
                workingDirectory: "/tmp/work",
                environment: nil,
                capturedAt: nil,
                source: nil
            ),
            preparedArguments: nil,
            observedPermissionMode: "bypassPermissions"
        )
        let invocation = try #require(AgentRestorePlanner(
            isExecutableFile: { $0 == "/shim/claude" }
        ).invocation(
            for: request,
            ambientEnvironment: ["CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude"]
        ))

        #expect(invocation.arguments.first == "/shim/claude")
        #expect(invocation.arguments.contains("--resume"))
        #expect(invocation.arguments.contains(sessionID))
        #expect(invocation.arguments.contains("--permission-mode"))
        #expect(invocation.arguments.contains("bypassPermissions"))
        #expect(
            invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"]
                == "claude:\(sessionID)"
        )
    }

    @Test func managedRestoreUsesCapturedExecutableWhenWrapperShimIsUnavailable() throws {
        let executable = "/opt/custom tools/codex"
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                executablePath: executable,
                arguments: [executable, "--model", "gpt-5.6-sol"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(
            isExecutableFile: { $0 == executable }
        ).invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments.first == executable)
        #expect(invocation.arguments.dropFirst().starts(with: ["resume", sessionID]))
        #expect(invocation.environment["CMUX_CUSTOM_CODEX_PATH"] == executable)
    }

    @Test func directBindingPreservesLongAndShortStructuredArgumentsIdentically() throws {
        let hazards = [
            "space value",
            "quote'\"",
            "日本語",
            "--cwd",
            "/tmp/空 白",
            String(repeating: "x", count: 4_000),
        ]
        let request = AgentRestoreRequest(
            mode: .direct,
            kind: "custom",
            checkpointID: nil,
            source: "cli",
            workingDirectory: "/tmp/空 白",
            environment: [
                "K": "値 with spaces",
                "OVERRIDE": "binding",
            ],
            launchCommand: AgentLaunchCommand(
                arguments: ["/usr/bin/printf"] + hazards,
                environment: [
                    "CAPTURED": "launch",
                    "OVERRIDE": "captured",
                ]
            ),
            preparedArguments: ["/usr/bin/printf"] + hazards,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner().invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments == ["/usr/bin/printf"] + hazards)
        #expect(invocation.environment["K"] == "値 with spaces")
        #expect(invocation.environment["CAPTURED"] == "launch")
        #expect(invocation.environment["OVERRIDE"] == "binding")
        #expect(invocation.workingDirectory == "/tmp/空 白")
    }

    @Test func structuredHermesRestoreUsesTypedPreflightsAndDirectArgv() throws {
        let executable = "/opt/Hermes Tools/hermes"
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "hermes-agent",
            checkpointID: "hermes-session-123",
            source: "agent-hook",
            workingDirectory: "/tmp/Hermes 项目",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "hermes-agent",
                executablePath: executable,
                arguments: [
                    executable,
                    "--provider",
                    "openai-codex",
                    "--model",
                    "gpt-5.5",
                ],
                workingDirectory: "/tmp/Hermes 项目",
                environment: [
                    HermesAgentCodexEnvironment.customBaseURLEnvironmentKey:
                        "http://subrouter-team:31415/v1",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner().invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments.first == executable)
        #expect(invocation.arguments.contains("--resume"))
        #expect(invocation.arguments.contains("hermes-session-123"))
        #expect(invocation.arguments.contains("openai-codex") == false)
        #expect(invocation.arguments.contains(HermesAgentCodexEnvironment.defaultProvider))
        #expect(invocation.preflightInvocations.count >= 3)
        #expect(invocation.preflightInvocations.allSatisfy {
            $0.arguments.first == executable &&
                Array($0.arguments.dropFirst().prefix(2)) == ["config", "set"]
        })
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("model.provider"))
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("model.base_url"))
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("model.api_mode"))
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("/bin/sh") == false)
    }

    @Test func structuredHermesExplicitProviderSkipsCodexPreflights() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "hermes-agent",
            checkpointID: "hermes-session-123",
            source: "agent-hook",
            workingDirectory: "/tmp/hermes",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                arguments: ["hermes", "--provider", "anthropic"],
                environment: [
                    HermesAgentCodexEnvironment.customBaseURLEnvironmentKey:
                        "http://subrouter-team:31415/v1",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner().invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments.contains("anthropic"))
        #expect(invocation.preflightInvocations.isEmpty)
    }
}
