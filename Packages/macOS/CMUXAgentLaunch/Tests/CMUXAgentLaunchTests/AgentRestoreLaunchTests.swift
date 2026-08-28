import Foundation
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

    @Test func hermesProviderOwnsWrapperConfiguration() throws {
        let launch = try #require(
            AgentRestoreLaunch(kind: " HERMES-Agent ", sessionID: "hermes-session-123")
        )

        #expect(launch.executableName == "hermes")
        #expect(
            launch.wrapperShellExecutableToken.contains(
                "CMUX_HERMES_AGENT_WRAPPER_SHIM"
            )
        )
        #expect(
            launch.customExecutablePathEnvironmentKey
                == "CMUX_CUSTOM_HERMES_AGENT_PATH"
        )
        #expect(
            launch.portableWrapperShellCommand(posixCommand: "wrapper --resume")
                .hasPrefix("/bin/sh -c ")
        )
    }

    @Test func invalidOwnershipCannotCreateRestoreLaunch() {
        #expect(AgentRestoreLaunch(kind: "gemini", sessionID: sessionID) == nil)
        #expect(AgentRestoreLaunch(kind: "codex", sessionID: "not-a-session-id") == nil)
        #expect(AgentRestoreLaunch(kind: nil, sessionID: sessionID) == nil)
        #expect(AgentRestoreLaunch(kind: "claude", sessionID: nil) == nil)
    }

    @Test func preflightInvocationRequiresExecutableArgument() throws {
        #expect(
            AgentRestorePreflightInvocation(
                arguments: [],
                environment: [:]
            ) == nil
        )
        let invocation = try #require(AgentRestorePreflightInvocation(
            arguments: ["/usr/bin/true", "config"],
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        #expect(invocation.executable == "/usr/bin/true")
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

    @Test func startupTokenIsTheReadableManagedPATHCommand() {
        #expect(AgentRestoreLaunch.cliStartupExecutableToken == "cmux")
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

    @Test func structuredSubrouterCodexRestoreUsesExplicitSrResumeCommand() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "-c",
                    "model_provider=subrouter",
                ],
                workingDirectory: "/tmp/project",
                environment: [
                    "SUBROUTER_CODEX_ACCOUNT_ID": "team-codex-1",
                    "SUBROUTER_CODEX_BASE_URL": "https://router.example.test/v1",
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "SUBROUTER_CODEX_SERVER": "team",
                    "SUBROUTER_CODEX_USER_EMAIL": "operator@example.test",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
                for: request,
                ambientEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        )

        #expect(invocation.arguments == [
            "sr", "codex", "resume", sessionID,
            "-c", "check_for_update_on_startup=false",
        ])
        #expect(invocation.environment["SUBROUTER_CODEX_ACCOUNT_ID"] == "team-codex-1")
        #expect(invocation.environment["SUBROUTER_CODEX_BASE_URL"] == "https://router.example.test/v1")
        #expect(invocation.environment["SUBROUTER_CODEX_RESUME_COMMAND"] == nil)
        #expect(invocation.environment["SUBROUTER_CODEX_SERVER"] == "team")
        #expect(invocation.environment["SUBROUTER_CODEX_USER_EMAIL"] == "operator@example.test")
        #expect(invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"] == nil)
    }

    @Test("Structured Subrouter restore preserves the captured launcher alias", arguments: ["subrouter", "cx"])
    func structuredSubrouterCodexRestorePreservesLauncherAlias(command: String) throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "-c", "model_provider=subrouter"],
                workingDirectory: "/tmp/project",
                environment: ["SUBROUTER_CODEX_RESUME_COMMAND": "\(command) codex resume"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
                for: request,
                ambientEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        )

        #expect(invocation.arguments == [
            command, "codex", "resume", sessionID,
            "-c", "check_for_update_on_startup=false",
        ])
    }

    @Test func structuredSubrouterRestoreRoutesItsChildThroughTheManagedCodexWrapper() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "-c", "model_provider=subrouter"],
                workingDirectory: "/tmp/project",
                environment: [
                    "SUBROUTER_CODEX_BIN": "/opt/bin/codex",
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { $0 == "/shim/codex" }).invocation(
                for: request,
                ambientEnvironment: [
                    "PATH": "/usr/bin:/bin",
                    "CMUX_CODEX_WRAPPER_SHIM": "/shim/codex",
                ]
            )
        )

        #expect(invocation.arguments.prefix(4) == ["sr", "codex", "resume", sessionID])
        #expect(invocation.environment["SUBROUTER_CODEX_BIN"] == "/shim/codex")
        #expect(invocation.environment["CMUX_CUSTOM_CODEX_PATH"] == "/opt/bin/codex")
        #expect(invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"] == "codex:\(sessionID)")
    }

    @Test func structuredSubrouterRestoreKeepsProvedLaunchRoutingInputsAuthoritative() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [
                "SUBROUTER_CODEX_ACCOUNT_ID": "replacement-account",
                "SUBROUTER_CODEX_BASE_URL": "https://replacement.example.test/v1",
                "SUBROUTER_CODEX_BIN": "/tmp/replacement-codex",
                "SUBROUTER_CODEX_RESUME_COMMAND": "cx codex resume",
                "SUBROUTER_CODEX_SERVER": "replacement-server",
                "SUBROUTER_CODEX_USER_EMAIL": "replacement@example.test",
            ],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "-c", "model_provider=subrouter"],
                workingDirectory: "/tmp/project",
                environment: [
                    "SUBROUTER_CODEX_ACCOUNT_ID": "captured-account",
                    "SUBROUTER_CODEX_BASE_URL": "https://captured.example.test/v1",
                    "SUBROUTER_CODEX_BIN": "/opt/bin/codex",
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "SUBROUTER_CODEX_SERVER": "captured-server",
                    "SUBROUTER_CODEX_USER_EMAIL": "captured@example.test",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
                for: request,
                ambientEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        )

        #expect(invocation.arguments.prefix(4) == ["sr", "codex", "resume", sessionID])
        #expect(invocation.environment["SUBROUTER_CODEX_ACCOUNT_ID"] == "captured-account")
        #expect(invocation.environment["SUBROUTER_CODEX_BASE_URL"] == "https://captured.example.test/v1")
        #expect(invocation.environment["SUBROUTER_CODEX_BIN"] == "/opt/bin/codex")
        #expect(invocation.environment["SUBROUTER_CODEX_RESUME_COMMAND"] == nil)
        #expect(invocation.environment["SUBROUTER_CODEX_SERVER"] == "captured-server")
        #expect(invocation.environment["SUBROUTER_CODEX_USER_EMAIL"] == "captured@example.test")
    }

    @Test func structuredCodexRestoreCanonicalizesRelativeHomeFromLaunchDirectory() throws {
        let launchDirectory = "/tmp/codex-launch-root/repository"
        let restoredDirectory = "/tmp/codex-launch-root/repository/worktree"
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: restoredDirectory,
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                arguments: ["codex"],
                workingDirectory: launchDirectory,
                environment: ["CODEX_HOME": ".codex"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
                for: request,
                ambientEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        )

        #expect(
            invocation.environment["CODEX_HOME"]
                == launchDirectory + "/.codex"
        )
    }

    @Test func structuredCodexRestoreExpandsHomeUsingCapturedLaunchHome() throws {
        let launchHome = "/tmp/codex-captured-home"
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/codex-project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                arguments: ["codex"],
                workingDirectory: "/tmp/codex-project",
                environment: ["CODEX_HOME": "~/.codex-work"],
                verificationHome: launchHome
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
                for: request,
                ambientEnvironment: [
                    "HOME": "/tmp/restoring-process-home",
                    "PATH": "/usr/bin:/bin",
                ]
            )
        )

        #expect(
            invocation.environment["CODEX_HOME"]
                == launchHome + "/.codex-work"
        )
    }

    @Test func structuredClaudeRestoreAppliesObservedPermissionModeWithoutParsingShell() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: " CLAUDE ",
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

    @Test func directBindingPreservesStructuredArgumentsBeyondFormerInlineBudget() throws {
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
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments == ["/usr/bin/printf"] + hazards)
        #expect(invocation.environment["K"] == "値 with spaces")
        #expect(invocation.environment["CAPTURED"] == "launch")
        #expect(invocation.environment["OVERRIDE"] == "binding")
        #expect(invocation.workingDirectory == "/tmp/空 白")
    }

    @Test func preparedRestoreArgumentsRetargetTheirPersistedWorkingDirectory() throws {
        let persistedWorkingDirectory = "/tmp/deleted 项目"
        let effectiveWorkingDirectory = "/tmp/fallback project"
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "cwd-agent",
            checkpointID: "session-123",
            source: "session-snapshot",
            workingDirectory: effectiveWorkingDirectory,
            environment: [:],
            launchCommand: AgentLaunchCommand(
                executablePath: "/opt/cwd-agent",
                arguments: ["/opt/cwd-agent"],
                workingDirectory: "/tmp/older captured cwd"
            ),
            preparedArguments: [
                "/opt/cwd-agent",
                "--cwd",
                persistedWorkingDirectory,
                "--workspace=\(persistedWorkingDirectory)",
                "--session",
                "session-123",
            ],
            preparedArgumentsWorkingDirectory: persistedWorkingDirectory,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.workingDirectory == effectiveWorkingDirectory)
        #expect(invocation.arguments.contains(effectiveWorkingDirectory))
        #expect(invocation.arguments.contains("--workspace=\(effectiveWorkingDirectory)"))
        #expect(invocation.arguments.contains(where: { $0.contains(persistedWorkingDirectory) }) == false)
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
        let invocation = try #require(AgentRestorePlanner(
            isExecutableFile: { $0 == "/shim/hermes" || $0 == executable }
        ).invocation(
            for: request,
            ambientEnvironment: [
                "HOME": "/Users/example",
                "PATH": "/usr/bin:/bin",
                "CMUX_HERMES_AGENT_WRAPPER_SHIM": "/shim/hermes",
            ]
        ))

        #expect(invocation.arguments.first == "/shim/hermes")
        #expect(Array(invocation.arguments.prefix(3)) == ["/shim/hermes", "--profile", "default"])
        #expect(invocation.environment["HERMES_HOME"] == "/Users/example/.hermes")
        #expect(invocation.environment["CMUX_CUSTOM_HERMES_AGENT_PATH"] == executable)
        #expect(
            invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"]
                == "hermes-agent:hermes-session-123"
        )
        #expect(invocation.arguments.contains("--resume"))
        #expect(invocation.arguments.contains("hermes-session-123"))
        #expect(invocation.arguments.contains("openai-codex") == false)
        #expect(invocation.arguments.contains(HermesAgentCodexEnvironment.defaultProvider))
        #expect(invocation.preflightInvocations.count >= 3)
        #expect(invocation.preflightInvocations.allSatisfy {
            Array($0.arguments.prefix(5))
                == ["/shim/hermes", "--profile", "default", "config", "set"]
        })
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("model.provider"))
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("model.base_url"))
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("model.api_mode"))
        #expect(invocation.preflightInvocations.flatMap(\.arguments).contains("/bin/sh") == false)
    }

    @Test func structuredHermesRestorePinsTheDefaultSessionStore() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "hermes-agent",
            checkpointID: "hermes-default-session",
            source: "agent-hook",
            workingDirectory: "/tmp/hermes",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "hermes-agent",
                arguments: ["hermes", "--tui", "--provider", "anthropic"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: [
                "HOME": "/Users/example",
                "PATH": "/usr/bin:/bin",
            ]
        ))

        #expect(invocation.environment["HERMES_HOME"] == "/Users/example/.hermes")
        #expect(
            invocation.arguments
                == [
                    "hermes",
                    "--profile", "default",
                    "--tui",
                    "--provider", "anthropic",
                    "--resume", "hermes-default-session",
                ]
        )
    }

    @Test func structuredHermesRestoreKeepsACapturedNamedProfile() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "hermes-agent",
            checkpointID: "hermes-coder-session",
            source: "agent-hook",
            workingDirectory: "/tmp/hermes",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "hermes-agent",
                arguments: ["hermes", "--tui", "--provider", "anthropic"],
                environment: ["HERMES_HOME": "/tmp/hermes/profiles/coder"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: [
                "HOME": "/Users/example",
                "HERMES_HOME": "/tmp/hermes/profiles/wrong",
                "PATH": "/usr/bin:/bin",
            ]
        ))

        #expect(invocation.environment["HERMES_HOME"] == "/tmp/hermes/profiles/coder")
        #expect(
            invocation.arguments
                == [
                    "hermes",
                    "--tui",
                    "--provider", "anthropic",
                    "--resume", "hermes-coder-session",
                ]
        )
    }

    @Test func structuredHermesRestoreKeepsAnExplicitProfileSelector() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "hermes-agent",
            checkpointID: "hermes-coder-session",
            source: "agent-hook",
            workingDirectory: "/tmp/hermes",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "hermes-agent",
                arguments: [
                    "hermes",
                    "--profile", "coder",
                    "--tui",
                    "--provider", "anthropic",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: [
                "HOME": "/Users/example",
                "PATH": "/usr/bin:/bin",
            ]
        ))

        #expect(invocation.environment["HERMES_HOME"] == "/Users/example/.hermes")
        #expect(invocation.arguments.filter { $0 == "--profile" }.count == 1)
        #expect(
            invocation.arguments
                == [
                    "hermes",
                    "--profile", "coder",
                    "--tui",
                    "--provider", "anthropic",
                    "--resume", "hermes-coder-session",
                ]
        )
    }

    @Test func structuredHermesRestoreUsesDefaultCodexBaseURLForPreflights() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        openai_base_url = "http://default-subrouter:31415/v1"
        model = "gpt-5.6-sol"
        """.write(
            to: codexHome.appendingPathComponent("config.toml", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: " HERMES-Agent ",
            checkpointID: "hermes-default-session",
            source: "agent-hook",
            workingDirectory: "/tmp/hermes",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                arguments: ["hermes", "--provider", "openai-codex"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: [
                "CODEX_HOME": codexHome.path,
                "PATH": "/usr/bin:/bin",
            ]
        ))
        let baseURLPreflight = try #require(
            invocation.preflightInvocations.first {
                $0.arguments.dropLast().last == "model.base_url"
            }
        )

        #expect(baseURLPreflight.arguments.last == "http://default-subrouter:31415/v1")
        #expect(
            baseURLPreflight.environment[
                HermesAgentCodexEnvironment.customBaseURLEnvironmentKey
            ] == "http://default-subrouter:31415/v1"
        )
        #expect(baseURLPreflight.environment["CODEX_HOME"] == codexHome.path)
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
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments.contains("anthropic"))
        #expect(invocation.preflightInvocations.isEmpty)
    }
}
