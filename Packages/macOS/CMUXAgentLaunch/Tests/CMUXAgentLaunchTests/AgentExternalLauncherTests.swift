import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Coverage for user-declared external launchers: the `agents.launchers` config shape, ancestor
/// detection, and re-supplying the launcher when a session resumes.
/// https://github.com/manaflow-ai/cmux/issues/10494
@Suite struct AgentExternalLauncherTests {
    private let sessionID = "0d15e2d1-ea11-4bcc-873e-e6167dc807aa"

    private static let teamclaude = AgentExternalLauncher(
        id: "teamclaude",
        kinds: ["claude"],
        argvExecutables: ["teamclaude"],
        resumeArgvPrefix: ["teamclaude", "run", "--auto-fallback", "--"]
    )

    private func registry(_ launchers: AgentExternalLauncher...) -> AgentExternalLauncherRegistry {
        AgentExternalLauncherRegistry(launchers: launchers)
    }

    @Test func declarationAcceptsSingularKindAndDetectString() throws {
        let json = Data("""
        {
          "agents": {
            "launchers": [
              {
                "id": "teamclaude",
                "kind": "claude",
                "detect": { "argvExecutables": "teamclaude" },
                "resumeArgvPrefix": ["teamclaude", "run", "--"]
              }
            ]
          }
        }
        """.utf8)

        let launcher = try #require(
            AgentExternalLauncherRegistry.decoding(sanitizedConfigJSON: json).launchers.first
        )

        #expect(launcher.id == "teamclaude")
        #expect(launcher.kinds == ["claude"])
        #expect(launcher.argvExecutables == ["teamclaude"])
        #expect(launcher.resumeArgvPrefix == ["teamclaude", "run", "--"])
        #expect(launcher.includesAgentExecutable == false)
    }

    @Test func declarationsThatCannotChangeARestoreAreDropped() {
        let missingDetect = AgentExternalLauncher(
            id: "no-detect",
            argvExecutables: [],
            resumeArgvPrefix: ["wrapper", "--"]
        )
        let missingPrefix = AgentExternalLauncher(
            id: "no-prefix",
            argvExecutables: ["wrapper"],
            resumeArgvPrefix: []
        )
        let missingID = AgentExternalLauncher(
            id: "  ",
            argvExecutables: ["wrapper"],
            resumeArgvPrefix: ["wrapper"]
        )
        let invalidID = AgentExternalLauncher(
            id: "team claude",
            argvExecutables: ["wrapper"],
            resumeArgvPrefix: ["wrapper"]
        )

        #expect(registry(missingDetect, missingPrefix, missingID, invalidID).launchers.isEmpty)
    }

    @Test func malformedConfigYieldsAnEmptyRegistryInsteadOfFailing() {
        #expect(
            AgentExternalLauncherRegistry
                .decoding(sanitizedConfigJSON: Data("{ not json".utf8))
                .launchers
                .isEmpty
        )
        #expect(
            AgentExternalLauncherRegistry
                .decoding(sanitizedConfigJSON: Data())
                .launchers
                .isEmpty
        )
    }

    @Test func laterDeclarationWinsForTheSameID() throws {
        let projectOverride = AgentExternalLauncher(
            id: "teamclaude",
            kinds: ["claude"],
            argvExecutables: ["teamclaude"],
            resumeArgvPrefix: ["teamclaude", "run", "--"]
        )
        let merged = registry(Self.teamclaude, projectOverride)

        #expect(merged.launchers.count == 1)
        #expect(try #require(merged.launchers.first).resumeArgvPrefix == ["teamclaude", "run", "--"])
    }

    /// A project file that overrides a user-level launcher and gets a field wrong must not fall back
    /// to the prefix it meant to replace — the override wins the id, then fails closed.
    @Test func abrokenProjectOverrideDoesNotRestoreTheUserLevelPrefix() {
        let userLevel = AgentExternalLauncher(
            id: "teamclaude",
            kinds: ["claude"],
            argvExecutables: ["teamclaude"],
            resumeArgvPrefix: ["teamclaude", "run", "--"]
        )
        let brokenProjectOverride = AgentExternalLauncher(
            id: "teamclaude",
            kinds: ["claude"],
            argvExecutables: [],
            resumeArgvPrefix: ["teamclaude", "run", "--auto-fallback", "--"]
        )

        let merged = registry(userLevel, brokenProjectOverride)

        #expect(merged.launchers.isEmpty)
        #expect(
            merged.applyingResumePrefix(
                to: ["/shim/claude", "--resume", sessionID],
                launcherID: "teamclaude",
                kind: "claude"
            ) == ["/shim/claude", "--resume", sessionID]
        )
    }

    @Test func detectionWalksAncestorsNearestFirst() throws {
        let outer = AgentExternalLauncher(
            id: "outer",
            kinds: ["claude"],
            argvExecutables: ["outer-wrapper"],
            resumeArgvPrefix: ["outer-wrapper", "--"]
        )
        let ancestors = [
            ["/bin/sh", "-c", "printf teamclaude"],
            ["node", "/usr/local/bin/teamclaude", "run", "--auto-fallback"],
            ["node", "/usr/local/bin/outer-wrapper"],
        ]

        let detected = try #require(
            registry(Self.teamclaude, outer).detectedLauncher(ancestorArgvs: ancestors, kind: "claude")
        )

        #expect(detected.id == "teamclaude")
    }

    @Test func detectionIgnoresLaunchersDeclaredForOtherKinds() {
        let detected = registry(Self.teamclaude).detectedLauncher(
            ancestorArgvs: [["node", "/usr/local/bin/teamclaude", "run"]],
            kind: "codex"
        )

        #expect(detected == nil)
    }

    @Test func declarationWithoutKindsMatchesEveryAgent() throws {
        let anyKind = AgentExternalLauncher(
            id: "gateway",
            argvExecutables: ["llm-gateway"],
            resumeArgvPrefix: ["llm-gateway", "exec", "--"]
        )

        for kind in ["claude", "codex", "opencode"] {
            let detected = try #require(
                registry(anyKind).detectedLauncher(
                    ancestorArgvs: [["llm-gateway", "serve"]],
                    kind: kind
                )
            )
            #expect(detected.id == "gateway")
        }
    }

    @Test func ancestorWalkIsDepthBoundedAndStopsAtTheProcessRoot() throws {
        // pid 20 is the agent; 21…29 are its ancestors, and only pid 29 is the wrapper.
        let parents: [pid_t: pid_t] = [
            20: 21, 21: 22, 22: 23, 23: 24, 24: 25, 25: 26, 26: 27, 27: 28, 28: 29, 29: 1,
        ]
        let argvByPID: [pid_t: [String]] = [
            29: ["node", "/usr/local/bin/teamclaude", "run"],
        ]
        let registry = registry(Self.teamclaude)

        #expect(
            registry.detectedLauncher(
                agentPID: 20,
                kind: "claude",
                maximumAncestorDepth: 3,
                parentPID: { parents[$0] ?? -1 },
                argv: { argvByPID[$0] }
            ) == nil
        )
        let detected = try #require(
            registry.detectedLauncher(
                agentPID: 20,
                kind: "claude",
                maximumAncestorDepth: 12,
                parentPID: { parents[$0] ?? -1 },
                argv: { argvByPID[$0] }
            )
        )
        #expect(detected.id == "teamclaude")

        var visited: [pid_t] = []
        _ = registry.detectedLauncher(
            agentPID: 20,
            kind: "claude",
            parentPID: { pid in
                visited.append(pid)
                return pid == 20 ? 1 : -1
            },
            argv: { _ in nil }
        )
        #expect(visited == [20])
    }

    @Test func launcherIdentityRequiresAnExactExecutableMatch() {
        let registry = registry(Self.teamclaude)

        // The name appears only inside an unrelated path the agent was given.
        #expect(
            registry.detectedLauncher(
                ancestorArgvs: [["claude", "--add-dir", "/Users/me/src/teamclaude-notes"]],
                kind: "claude"
            ) == nil
        )
        // A longer executable name that merely starts with the declared one is a different program.
        #expect(
            registry.detectedLauncher(
                ancestorArgvs: [["/usr/local/bin/teamclaude-legacy", "run"]],
                kind: "claude"
            ) == nil
        )
        // The launcher itself, either bare or behind an interpreter, does match.
        #expect(registry.detectedLauncher(ancestorArgvs: [["teamclaude", "run"]], kind: "claude") != nil)
        #expect(
            registry.detectedLauncher(
                ancestorArgvs: [["node", "/usr/local/bin/teamclaude", "run", "--auto-fallback"]],
                kind: "claude"
            ) != nil
        )
    }

    @Test func launcherIsIdentifiedOnlyInTheExecutablePosition() {
        let registry = registry(Self.teamclaude)

        // Not the executable: a shell's `-c` payload, or any later argument.
        #expect(
            registry.detectedLauncher(
                ancestorArgvs: [["/bin/zsh", "-lc", "--", "something", "teamclaude"]],
                kind: "claude"
            ) == nil
        )
        #expect(
            registry.detectedLauncher(
                ancestorArgvs: [["claude", "--resume", "id", "--add-dir", "teamclaude"]],
                kind: "claude"
            ) == nil
        )
    }

    /// A launcher can sit behind an env prefix or an interpreter, at any offset those imply, and
    /// still be the program that was run. https://github.com/manaflow-ai/cmux/pull/10503
    @Test(arguments: [
        ["llm-gateway", "exec", "--", "claude"],
        ["env", "VAR1=1", "VAR2=2", "VAR3=3", "llm-gateway", "exec", "--", "claude"],
        ["/usr/bin/env", "-u", "NODE_OPTIONS", "VAR=1", "/opt/bin/llm-gateway", "exec"],
        ["env", "VAR=1", "node", "/usr/local/lib/llm-gateway", "exec"],
        ["npx", "--yes", "llm-gateway", "exec"],
        // `--` ends env's own options; the program follows it.
        ["env", "--", "llm-gateway", "exec"],
        ["env", "-i", "VAR=1", "--", "/opt/bin/llm-gateway", "exec"],
        // A joined `--opt=value` carries its value in the same word.
        ["env", "--chdir=/tmp", "llm-gateway", "exec"],
        ["env", "--unset=NODE_OPTIONS", "VAR=1", "llm-gateway", "exec"],
        ["npx", "--yes=true", "llm-gateway", "exec"],
    ])
    func forwardingCommandsDoNotHideTheLauncher(argv: [String]) throws {
        let gateway = AgentExternalLauncher(
            id: "gateway",
            kinds: ["claude"],
            argvExecutables: ["llm-gateway"],
            resumeArgvPrefix: ["llm-gateway", "exec", "--"]
        )

        let detected = try #require(
            registry(gateway).detectedLauncher(ancestorArgvs: [argv], kind: "claude")
        )
        #expect(detected.id == "gateway")
    }

    /// `-` means different things per command: `env -` is the empty-environment shorthand and the
    /// program still follows, while `node -` / `python3 -` read the program from stdin, so a later
    /// word is that program's argument, not an executable.
    @Test func bareDashIsReadPerForwardingCommand() throws {
        let gateway = AgentExternalLauncher(
            id: "gateway",
            kinds: ["claude"],
            argvExecutables: ["llm-gateway"],
            resumeArgvPrefix: ["llm-gateway", "exec", "--"]
        )
        let registry = registry(gateway)

        #expect(
            registry.detectedLauncher(ancestorArgvs: [["node", "-", "llm-gateway"]], kind: "claude") == nil
        )
        #expect(
            registry.detectedLauncher(
                ancestorArgvs: [["python3", "-", "llm-gateway", "exec"]],
                kind: "claude"
            ) == nil
        )
        let detected = try #require(
            registry.detectedLauncher(
                ancestorArgvs: [["env", "-", "VAR=1", "llm-gateway", "exec"]],
                kind: "claude"
            )
        )
        #expect(detected.id == "gateway")
    }

    /// An option that carries the program inline ends the search: every later word belongs to that
    /// inline program, so treating one as an executable would attribute the session to a launcher
    /// that never ran.
    @Test func inlineProgramOptionsEndTheSearch() throws {
        let gateway = AgentExternalLauncher(
            id: "gateway",
            kinds: ["claude"],
            argvExecutables: ["llm-gateway"],
            resumeArgvPrefix: ["llm-gateway", "exec", "--"]
        )
        let registry = registry(gateway)

        for argv in [
            ["python3", "-c", "import runpy", "llm-gateway"],
            ["node", "-e", "require('x')", "llm-gateway", "exec"],
            ["node", "--eval", "run()", "llm-gateway"],
            ["npx", "--call", "build", "llm-gateway"],
            // A runner option that takes a value would otherwise make the value the "launcher".
            ["npx", "--package", "some-pkg", "llm-gateway", "exec"],
            ["pnpm", "--filter", "app", "llm-gateway"],
            // An unknown env option is not guessed at either.
            ["env", "--some-future-flag", "llm-gateway", "exec"],
            // An interpreter option can name a module or change resolution instead of carrying the
            // program inline; the search stops at the first option either way.
            ["python3", "-m", "runpy", "llm-gateway"],
            ["node", "--import", "./hook.js", "llm-gateway"],
        ] {
            #expect(registry.detectedLauncher(ancestorArgvs: [argv], kind: "claude") == nil)
        }

        // `env` has no inline-program option, and its value-taking options are still followed by
        // the program.
        let detected = try #require(
            registry.detectedLauncher(
                ancestorArgvs: [["env", "-u", "NODE_OPTIONS", "-C", "/tmp", "llm-gateway", "exec"]],
                kind: "claude"
            )
        )
        #expect(detected.id == "gateway")
    }

    @Test func forwardingIsNotFollowedIndefinitely() {
        // env -> node -> npx are two hops plus a third executable; `teamclaude` sits behind all of
        // them, so it is out of reach and the session stays unwrapped rather than being attributed
        // through an arbitrarily long chain.
        let deep = ["env", "VAR=1", "node", "/usr/local/bin/npx", "teamclaude", "run"]
        #expect(registry(Self.teamclaude).detectedLauncher(ancestorArgvs: [deep], kind: "claude") == nil)

        // One hop shallower is still identified.
        let reachable = ["env", "VAR=1", "/usr/local/bin/npx", "teamclaude", "run"]
        #expect(registry(Self.teamclaude).detectedLauncher(ancestorArgvs: [reachable], kind: "claude") != nil)
    }

    @Test func declaredButUnusableFieldsFailClosed() {
        func launchers(_ body: String) -> [AgentExternalLauncher] {
            AgentExternalLauncherRegistry
                .decoding(sanitizedConfigJSON: Data("{ \"agents\": { \"launchers\": [\(body)] } }".utf8))
                .launchers
        }

        let valid = """
        { "id": "teamclaude", "detect": { "argvExecutables": ["teamclaude"] },
          "resumeArgvPrefix": ["teamclaude", "run", "--"] }
        """
        #expect(launchers(valid).count == 1)

        // An empty or blank kinds list must not widen the launcher to every agent.
        #expect(launchers("""
        { "id": "teamclaude", "kinds": [], "detect": { "argvExecutables": ["teamclaude"] },
          "resumeArgvPrefix": ["teamclaude", "run", "--"] }
        """).isEmpty)
        #expect(launchers("""
        { "id": "teamclaude", "kinds": ["  "], "detect": { "argvExecutables": ["teamclaude"] },
          "resumeArgvPrefix": ["teamclaude", "run", "--"] }
        """).isEmpty)
        // Wrong types anywhere the user wrote something.
        #expect(launchers("""
        { "id": "teamclaude", "kind": 7, "detect": { "argvExecutables": ["teamclaude"] },
          "resumeArgvPrefix": ["teamclaude", "run", "--"] }
        """).isEmpty)
        #expect(launchers("""
        { "id": "teamclaude", "detect": { "argvExecutables": ["teamclaude"] },
          "resumeArgvPrefix": "teamclaude run --" }
        """).isEmpty)
        #expect(launchers("""
        { "id": "teamclaude", "detect": ["teamclaude"],
          "resumeArgvPrefix": ["teamclaude", "run", "--"] }
        """).isEmpty)
        #expect(launchers("""
        { "id": "teamclaude", "detect": { "argvExecutables": ["teamclaude"] },
          "resumeArgvPrefix": ["teamclaude", "run", "--"], "includesAgentExecutable": "yes" }
        """).isEmpty)
        // One unusable declaration must not take the rest of the file down with it.
        let mixed = launchers("""
        { "id": "broken", "detect": { "argvExecutables": [] }, "resumeArgvPrefix": ["x"] },
        \(valid)
        """)
        #expect(mixed.map(\.id) == ["teamclaude"])
    }

    @Test func declaringBothKindAndKindsFailsClosed() {
        let launchers = AgentExternalLauncherRegistry.decoding(sanitizedConfigJSON: Data("""
        { "agents": { "launchers": [
          { "id": "teamclaude", "kind": "claude", "kinds": ["codex"],
            "detect": { "argvExecutables": ["teamclaude"] },
            "resumeArgvPrefix": ["teamclaude", "run", "--"] }
        ] } }
        """.utf8)).launchers

        // Preferring one key would silently discard the other; the two together are ambiguous.
        #expect(launchers.isEmpty)
    }

    /// Hermes resumes carry preflight `config set` commands built from the agent argv. Those are
    /// whole commands, so a launcher has to wrap each of them too — otherwise a preflight becomes
    /// `<wrapper> config set …`, losing the wrapper's own subcommand and the agent.
    @Test func wrappedHermesPreflightsKeepTheWholeLauncherPrefix() throws {
        let executable = "/opt/hermes/hermes"
        let teamhermes = AgentExternalLauncher(
            id: "teamhermes",
            kinds: ["hermes-agent"],
            argvExecutables: ["teamhermes"],
            resumeArgvPrefix: ["teamhermes", "exec", "--"]
        )
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "hermes-agent",
            checkpointID: "hermes-session-123",
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "hermes-agent",
                externalLauncher: "teamhermes",
                executablePath: executable,
                arguments: [executable, "--provider", "openai-codex"],
                workingDirectory: "/tmp/work",
                environment: [
                    HermesAgentCodexEnvironment.customBaseURLEnvironmentKey:
                        "http://subrouter-team:31415/v1",
                ]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(
                isExecutableFile: { $0 == "/shim/hermes" || $0 == executable },
                externalLaunchers: registry(teamhermes)
            ).invocation(
                for: request,
                ambientEnvironment: [
                    "HOME": "/Users/example",
                    "PATH": "/usr/bin:/bin",
                    "CMUX_HERMES_AGENT_WRAPPER_SHIM": "/shim/hermes",
                ]
            )
        )

        #expect(Array(invocation.arguments.prefix(3)) == ["teamhermes", "exec", "--"])
        #expect(invocation.environment["PATH"] == "/shim:/usr/bin:/bin")
        #expect(invocation.preflightInvocations.isEmpty == false)
        for preflight in invocation.preflightInvocations {
            #expect(Array(preflight.arguments.prefix(3)) == ["teamhermes", "exec", "--"])
            // Each preflight runs the same agent through the same wrapper, so it needs the shim on
            // PATH too — otherwise the preflight's agent invocation loses cmux's hooks.
            #expect(preflight.environment["PATH"] == "/shim:/usr/bin:/bin")
            // The profile pin and the `config set` verb survive after the prefix.
            #expect(preflight.arguments.contains("config"))
            #expect(preflight.arguments.contains("set"))
            #expect(preflight.arguments.contains("--profile"))
            // The agent executable is dropped exactly once — the wrapper re-execs its own.
            #expect(preflight.arguments.contains("/shim/hermes") == false)
            #expect(preflight.arguments.contains(executable) == false)
        }
    }

    /// Hook captures for one session are compared for durable resume evidence, and the winner may be
    /// a record whose ancestor detection missed (the launcher process can already be gone). The id
    /// has to survive that comparison or a later hook silently unwraps the session.
    @Test func externalLauncherSurvivesRecordMerging() {
        let withLauncher = AgentLaunchCommand(
            launcher: "claude",
            externalLauncher: "teamclaude",
            arguments: ["/opt/claude"]
        )
        let withoutLauncher = AgentLaunchCommand(launcher: "claude", arguments: ["/opt/claude"])
        let blankLauncher = AgentLaunchCommand(
            launcher: "claude",
            externalLauncher: "   ",
            arguments: ["/opt/claude"]
        )

        #expect(
            withoutLauncher.preservingExternalLauncher(from: [withLauncher]).externalLauncher
                == "teamclaude"
        )
        #expect(
            blankLauncher.preservingExternalLauncher(from: [nil, withLauncher]).externalLauncher
                == "teamclaude"
        )
        // An id the record already carries wins over the candidates.
        let other = AgentLaunchCommand(
            launcher: "claude",
            externalLauncher: "gateway",
            arguments: ["/opt/claude"]
        )
        #expect(
            withLauncher.preservingExternalLauncher(from: [other]).externalLauncher == "teamclaude"
        )
        // Candidates are consulted in order.
        #expect(
            withoutLauncher.preservingExternalLauncher(from: [other, withLauncher]).externalLauncher
                == "gateway"
        )
        // A padded id is stored canonically, so it matches a declaration after a socket round trip.
        let padded = AgentLaunchCommand(
            launcher: "claude",
            externalLauncher: " teamclaude ",
            arguments: ["/opt/claude"]
        )
        #expect(padded.preservingExternalLauncher(from: []).externalLauncher == "teamclaude")
        // Nothing to recover leaves the record untouched.
        #expect(
            withoutLauncher.preservingExternalLauncher(from: [nil, blankLauncher]) == withoutLauncher
        )
    }

    /// The shim directory holds one file, so making it the whole `PATH` would leave the wrapper
    /// itself unresolvable — a failed resume instead of a resume without hooks.
    @Test func shimRoutingOnlyEverPrefixesAnExistingPath() {
        let shimmed = AgentExternalLauncherRegistry.environmentRoutingWrappedAgentThroughShim(
            ["CMUX_CLAUDE_WRAPPER_SHIM": "/tmp/shims/claude", "PATH": "/usr/bin:/bin"],
            shimEnvironmentKey: "CMUX_CLAUDE_WRAPPER_SHIM",
            isExecutableFile: { $0 == "/tmp/shims/claude" }
        )
        #expect(shimmed["PATH"] == "/tmp/shims:/usr/bin:/bin")

        for environment in [
            ["CMUX_CLAUDE_WRAPPER_SHIM": "/tmp/shims/claude"],
            ["CMUX_CLAUDE_WRAPPER_SHIM": "/tmp/shims/claude", "PATH": ""],
        ] {
            let untouched = AgentExternalLauncherRegistry.environmentRoutingWrappedAgentThroughShim(
                environment,
                shimEnvironmentKey: "CMUX_CLAUDE_WRAPPER_SHIM",
                isExecutableFile: { $0 == "/tmp/shims/claude" }
            )
            #expect(untouched == environment)
        }

        // Already first: left alone rather than duplicated.
        let idempotent = AgentExternalLauncherRegistry.environmentRoutingWrappedAgentThroughShim(
            ["CMUX_CLAUDE_WRAPPER_SHIM": "/tmp/shims/claude", "PATH": "/tmp/shims:/usr/bin"],
            shimEnvironmentKey: "CMUX_CLAUDE_WRAPPER_SHIM",
            isExecutableFile: { $0 == "/tmp/shims/claude" }
        )
        #expect(idempotent["PATH"] == "/tmp/shims:/usr/bin")
    }

    @Test func wrappedResumeKeepsTheAgentShimReachableOnPath() throws {
        func invocation(includesAgentExecutable: Bool) throws -> AgentRestoreInvocation {
            let launcher = AgentExternalLauncher(
                id: "teamclaude",
                kinds: ["claude"],
                argvExecutables: ["teamclaude"],
                resumeArgvPrefix: ["teamclaude", "run", "--"],
                includesAgentExecutable: includesAgentExecutable
            )
            let request = AgentRestoreRequest(
                mode: .resumeAgent,
                kind: "claude",
                checkpointID: sessionID,
                source: "agent-hook",
                workingDirectory: "/tmp/work",
                environment: [:],
                launchCommand: AgentLaunchCommand(
                    launcher: "claude",
                    externalLauncher: "teamclaude",
                    executablePath: "/opt/claude",
                    arguments: ["/opt/claude"],
                    workingDirectory: "/tmp/work",
                    source: "environment"
                ),
                preparedArguments: nil,
                observedPermissionMode: nil
            )
            return try #require(
                AgentRestorePlanner(
                    isExecutableFile: { $0 == "/tmp/shims/claude" },
                    externalLaunchers: registry(launcher)
                ).invocation(
                    for: request,
                    ambientEnvironment: [
                        "CMUX_CLAUDE_WRAPPER_SHIM": "/tmp/shims/claude",
                        "PATH": "/usr/bin:/bin",
                    ]
                )
            )
        }

        // The prefix replaced the agent executable, so the wrapper's own `claude` lookup has to
        // find cmux's shim or the resumed session runs without hooks.
        let wrapped = try invocation(includesAgentExecutable: false)
        #expect(wrapped.environment["PATH"] == "/tmp/shims:/usr/bin:/bin")

        // The wrapper receives the shim path itself here, so PATH is left alone.
        let passesExecutable = try invocation(includesAgentExecutable: true)
        #expect(passesExecutable.environment["PATH"] == "/usr/bin:/bin")
        #expect(passesExecutable.arguments.contains("/tmp/shims/claude"))
    }

    @Test func storedShellCommandDefersShimResolutionToReplayTime() {
        let command = AgentExternalLauncherRegistry.portableShellCommandRoutingWrappedAgentThroughShim(
            posixCommand: "teamclaude run -- --resume \(sessionID)",
            shimEnvironmentKey: "CMUX_CLAUDE_WRAPPER_SHIM"
        )

        #expect(command.hasPrefix("/bin/sh -c "))
        #expect(command.contains("PATH="))
        // The shim directory is derived from the managed variable when the command runs, because a
        // stored binding outlives the shim file it was created with.
        #expect(command.contains("${CMUX_CLAUDE_WRAPPER_SHIM:+${CMUX_CLAUDE_WRAPPER_SHIM%/*}:}$PATH"))
        #expect(command.contains("teamclaude run -- --resume \(sessionID)"))
    }

    @Test func loadMergesUserAndProjectConfigsWithProjectWinning() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-external-launcher-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project/nested", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".config/cmux", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("project/.cmux", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("""
        {
          // user level
          "agents": { "launchers": [
            { "id": "teamclaude", "detect": { "argvExecutables": "teamclaude" },
              "resumeArgvPrefix": ["teamclaude", "run", "--"] },
            { "id": "gateway", "detect": { "argvExecutables": "llm-gateway" },
              "resumeArgvPrefix": ["llm-gateway", "exec", "--"] }
          ] }
        }
        """.utf8).write(to: home.appendingPathComponent(".config/cmux/cmux.json"))
        try Data("""
        { "agents": { "launchers": [
          { "id": "teamclaude", "detect": { "argvExecutables": "teamclaude" },
            "resumeArgvPrefix": ["teamclaude", "run", "--auto-fallback", "--"] }
        ] } }
        """.utf8).write(to: root.appendingPathComponent("project/.cmux/cmux.json"))

        let loaded = AgentExternalLauncherRegistry.load(
            homeDirectory: home.path,
            workingDirectory: project.path,
            sanitize: { data in
                // Stand-in for the app's JSONC preprocessing.
                guard let text = String(data: data, encoding: .utf8) else { return data }
                let stripped = text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                return Data(stripped.utf8)
            }
        )

        #expect(loaded.launchers.map(\.id) == ["teamclaude", "gateway"])
        #expect(
            try #require(loaded.launcher(id: "teamclaude")).resumeArgvPrefix
                == ["teamclaude", "run", "--auto-fallback", "--"]
        )
    }

    @Test func resumePrefixReplacesTheAgentExecutableByDefault() {
        let wrapped = registry(Self.teamclaude).applyingResumePrefix(
            to: ["/shim/claude", "--resume", sessionID, "--permission-mode", "auto"],
            launcherID: "teamclaude",
            kind: "claude"
        )

        #expect(
            wrapped == [
                "teamclaude", "run", "--auto-fallback", "--",
                "--resume", sessionID, "--permission-mode", "auto",
            ]
        )
    }

    @Test func resumePrefixKeepsTheAgentExecutableWhenDeclared() {
        let envStyle = AgentExternalLauncher(
            id: "gateway",
            kinds: ["claude"],
            argvExecutables: ["llm-gateway"],
            resumeArgvPrefix: ["llm-gateway", "exec", "--"],
            includesAgentExecutable: true
        )

        let wrapped = registry(envStyle).applyingResumePrefix(
            to: ["/shim/claude", "--resume", sessionID],
            launcherID: "gateway",
            kind: "claude"
        )

        #expect(wrapped == ["llm-gateway", "exec", "--", "/shim/claude", "--resume", sessionID])
    }

    @Test func argvIsUnchangedWithoutAnApplicableDeclaration() {
        let argv = ["/shim/claude", "--resume", sessionID]

        // Capture recorded a launcher the user has since removed from cmux.json.
        #expect(
            registry(Self.teamclaude).applyingResumePrefix(
                to: argv,
                launcherID: "removed-wrapper",
                kind: "claude"
            ) == argv
        )
        // Nothing was detected at capture time.
        #expect(
            registry(Self.teamclaude).applyingResumePrefix(
                to: argv,
                launcherID: nil,
                kind: "claude"
            ) == argv
        )
        // The declaration does not wrap this agent kind.
        #expect(
            registry(Self.teamclaude).applyingResumePrefix(
                to: argv,
                launcherID: "teamclaude",
                kind: "codex"
            ) == argv
        )
        // No declarations at all.
        #expect(
            AgentExternalLauncherRegistry.empty.applyingResumePrefix(
                to: argv,
                launcherID: "teamclaude",
                kind: "claude"
            ) == argv
        )
    }

    @Test func structuredClaudeResumeReSuppliesTheExternalLauncher() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "claude",
                externalLauncher: "teamclaude",
                executablePath: "/opt/claude",
                arguments: ["/opt/claude", "--permission-mode", "auto"],
                workingDirectory: "/tmp/work",
                source: "environment"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(
                isExecutableFile: { $0 == "/shim/claude" },
                externalLaunchers: registry(Self.teamclaude)
            ).invocation(
                for: request,
                ambientEnvironment: ["CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude"]
            )
        )

        #expect(Array(invocation.arguments.prefix(4)) == ["teamclaude", "run", "--auto-fallback", "--"])
        #expect(invocation.arguments.contains("--resume"))
        #expect(invocation.arguments.contains(sessionID))
        #expect(invocation.arguments.contains("/shim/claude") == false)
        // The launch stays authorized as a claude restore, so the wrapper's own child claude keeps
        // the cmux launch identity.
        #expect(invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"] == "claude:\(sessionID)")
    }

    /// The working-directory sanitizer and the provider rewrites target the agent's own argv, so the
    /// launcher prefix is applied after them: a prefix may legitimately carry the same path the
    /// capture recorded as its working directory, and stripping it would break the wrapper's own
    /// invocation.
    @Test func launcherPrefixSurvivesWorkingDirectorySanitizing() throws {
        let workingDirectory = "/tmp/work"
        // `--cwd` is one of the options the working-directory sanitizer strips, so this pins the
        // ordering rather than merely passing by accident.
        let pinnedLauncher = AgentExternalLauncher(
            id: "teamclaude",
            kinds: ["claude"],
            argvExecutables: ["teamclaude"],
            resumeArgvPrefix: ["teamclaude", "run", "--cwd", workingDirectory, "--"]
        )
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: workingDirectory,
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "claude",
                externalLauncher: "teamclaude",
                executablePath: "/opt/claude",
                arguments: ["/opt/claude", "--add-dir", workingDirectory],
                workingDirectory: workingDirectory,
                source: "environment"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(
                isExecutableFile: { $0 == "/shim/claude" },
                externalLaunchers: registry(pinnedLauncher)
            ).invocation(
                for: request,
                ambientEnvironment: ["CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude", "PATH": "/usr/bin"]
            )
        )

        #expect(
            Array(invocation.arguments.prefix(5))
                == ["teamclaude", "run", "--cwd", workingDirectory, "--"]
        )
        // The prefix is intact as one contiguous run, and the agent's resume argv follows it.
        #expect(invocation.arguments.dropFirst(5).contains("--resume"))
        #expect(invocation.arguments.dropFirst(5).contains(sessionID))
    }

    @Test func structuredResumeWithoutADeclarationKeepsTheBareAgentInvocation() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "claude",
                externalLauncher: "teamclaude",
                executablePath: "/opt/claude",
                arguments: ["/opt/claude"],
                workingDirectory: "/tmp/work",
                source: "environment"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { $0 == "/shim/claude" }).invocation(
                for: request,
                ambientEnvironment: ["CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude"]
            )
        )

        #expect(invocation.arguments.first == "/shim/claude")
        #expect(invocation.arguments.contains("teamclaude") == false)
    }

    @Test func directRestoreIsNeverWrapped() throws {
        let request = AgentRestoreRequest(
            mode: .direct,
            kind: "claude",
            checkpointID: sessionID,
            source: "cli",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "claude",
                externalLauncher: "teamclaude",
                executablePath: "/opt/claude",
                arguments: ["/opt/claude", "--version"],
                workingDirectory: "/tmp/work",
                source: "environment"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            AgentRestorePlanner(
                isExecutableFile: { _ in true },
                externalLaunchers: registry(Self.teamclaude)
            ).invocation(for: request, ambientEnvironment: [:])
        )

        #expect(invocation.arguments == ["/opt/claude", "--version"])
    }
}
