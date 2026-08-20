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
        argvContains: ["teamclaude"],
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
                "detect": { "argvContains": "teamclaude" },
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
        #expect(launcher.argvContains == ["teamclaude"])
        #expect(launcher.resumeArgvPrefix == ["teamclaude", "run", "--"])
        #expect(launcher.includesAgentExecutable == false)
    }

    @Test func declarationsThatCannotChangeARestoreAreDropped() {
        let missingDetect = AgentExternalLauncher(
            id: "no-detect",
            argvContains: [],
            resumeArgvPrefix: ["wrapper", "--"]
        )
        let missingPrefix = AgentExternalLauncher(
            id: "no-prefix",
            argvContains: ["wrapper"],
            resumeArgvPrefix: []
        )
        let missingID = AgentExternalLauncher(
            id: "  ",
            argvContains: ["wrapper"],
            resumeArgvPrefix: ["wrapper"]
        )
        let invalidID = AgentExternalLauncher(
            id: "team claude",
            argvContains: ["wrapper"],
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
            argvContains: ["teamclaude"],
            resumeArgvPrefix: ["teamclaude", "run", "--"]
        )
        let merged = registry(Self.teamclaude, projectOverride)

        #expect(merged.launchers.count == 1)
        #expect(try #require(merged.launchers.first).resumeArgvPrefix == ["teamclaude", "run", "--"])
    }

    @Test func detectionWalksAncestorsNearestFirst() throws {
        let outer = AgentExternalLauncher(
            id: "outer",
            kinds: ["claude"],
            argvContains: ["outer-wrapper"],
            resumeArgvPrefix: ["outer-wrapper", "--"]
        )
        let ancestors = [
            ["/bin/sh", "-c", "teamclaude run"],
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
            argvContains: ["llm-gateway"],
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
            argvContains: ["llm-gateway"],
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
