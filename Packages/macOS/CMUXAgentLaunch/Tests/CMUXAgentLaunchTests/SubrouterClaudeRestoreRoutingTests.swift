import Foundation
import Testing
@testable import CMUXAgentLaunch

/// `sr claude proxy` launches Claude with a private, per-launch `--settings` file
/// that carries the proxy token, account routing headers and base URL, and
/// deletes it when `sr` exits. Replaying the captured `claude --resume <id>`
/// therefore restores a session with none of that routing. A restore that can
/// prove the launch went through Subrouter must re-invoke the launcher instead.
@Suite("Claude restore re-invokes sr claude proxy for a proven Subrouter launch")
struct SubrouterClaudeRestoreRoutingTests {
    private let sessionID = "0198f073-0a5b-7000-8000-000000000059"
    private let marker = "sr claude proxy --resume"
    private let markerKey = "SUBROUTER_CLAUDE_RESUME_COMMAND"
    private let launchBoundMarkerKey = "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND"
    private let localPoolBaseURL = "http://127.0.0.1:31415/v1"
    private let capturedClaude = "/opt/homebrew/bin/claude"
    private let capturedConfigDir = "/Users/me/.subrouter/codex/claude-proxy/3fa7ce27b6c3bad79bd47d1a"

    private func routedLaunchEnvironment(
        baseURL: String,
        marker: String? = nil,
        launchBoundMarker: String? = nil
    ) -> [String: String] {
        var environment = [
            "ANTHROPIC_BASE_URL": baseURL,
            "CLAUDE_CONFIG_DIR": capturedConfigDir,
        ]
        environment[markerKey] = marker
        environment[launchBoundMarkerKey] = launchBoundMarker
        return environment
    }

    private func resumeRequest(
        arguments: [String]? = nil,
        environment: [String: String],
        launcher: String? = nil,
        mode: AgentRestoreRequestMode = .resumeAgent,
        observedPermissionMode: String? = nil
    ) -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: mode,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: launcher,
                executablePath: capturedClaude,
                arguments: arguments ?? [capturedClaude, "--model", "opus"],
                workingDirectory: "/tmp/project",
                environment: environment,
                capturedAt: 1,
                source: "test"
            ),
            preparedArguments: nil,
            observedPermissionMode: observedPermissionMode
        )
    }

    /// `sr` on PATH and the per-surface claude shim both exist.
    private func plannerWithSubrouterOnPath() -> AgentRestorePlanner {
        AgentRestorePlanner(isExecutableFile: { path in
            path == "/opt/homebrew/bin/sr" || path == "/shim/claude"
        })
    }

    private let ambientEnvironment = [
        "PATH": "/tmp/cmux-shims:/opt/homebrew/bin:/usr/bin:/bin",
        "CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude",
        "HOME": "/Users/me",
    ]

    private func expectPlainClaudeReplay(
        _ invocation: AgentRestoreInvocation,
        baseURL: String,
        _ label: String
    ) {
        #expect(invocation.arguments.first == "/shim/claude", "\(label): \(invocation.arguments)")
        #expect(invocation.arguments.contains("sr") == false, "\(label): \(invocation.arguments)")
        #expect(invocation.arguments.contains("proxy") == false, "\(label): \(invocation.arguments)")
        #expect(invocation.arguments.contains("--resume"), "\(label): \(invocation.arguments)")
        #expect(invocation.arguments.contains(sessionID), "\(label): \(invocation.arguments)")
        // The existing replay keeps carrying the auth selection it captured.
        #expect(invocation.environment["ANTHROPIC_BASE_URL"] == baseURL, "\(label)")
        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == capturedConfigDir, "\(label)")
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] == "1", "\(label)")
        // Record evidence never becomes a child environment for a plain replay.
        #expect(invocation.environment[markerKey] == nil, "\(label)")
        #expect(invocation.environment[launchBoundMarkerKey] == nil, "\(label)")
    }

    @Test(
        "A proven Subrouter launch restores through sr claude proxy --resume, local pool or hosted",
        arguments: ["http://127.0.0.1:31415/v1", "https://sr.cmux.com/v1"]
    )
    func provenRoutedLaunchReinvokesSubrouter(baseURL: String) throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: baseURL,
                marker: marker,
                launchBoundMarker: marker
            )
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        #expect(
            invocation.arguments == ["sr", "claude", "proxy", "--resume", sessionID, "--model", "opus"],
            "\(invocation.arguments)"
        )
        #expect(invocation.workingDirectory == "/tmp/project")
        // Subrouter regenerates auth selection from the live pool; the captured
        // values must not be re-injected around it.
        #expect(invocation.environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] == nil)
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] == nil)
        #expect(invocation.environment[markerKey] == nil)
        #expect(invocation.environment[launchBoundMarkerKey] == nil)
        // The wrapper `sr` reaches through PATH still recognises an app-owned restore
        // and keeps launching the same Claude binary.
        #expect(invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"] == "claude:\(sessionID)")
        #expect(invocation.environment["CMUX_CUSTOM_CLAUDE_PATH"] == capturedClaude)
        #expect(invocation.environment["PATH"] == ambientEnvironment["PATH"])
        #expect(invocation.preflightInvocations.isEmpty)
    }

    @Test("The routed restore re-applies the observed permission mode after the session id")
    func routedRestoreAppliesObservedPermissionMode() throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: marker,
                launchBoundMarker: marker
            ),
            observedPermissionMode: "bypassPermissions"
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        #expect(invocation.arguments.starts(with: ["sr", "claude", "proxy", "--resume", sessionID]))
        #expect(invocation.arguments.suffix(2) == ["--permission-mode", "bypassPermissions"])
    }

    @Test("The routed restore drops Subrouter's private --settings file from a captured argv")
    func routedRestoreDropsSubrouterPrivateSettings() throws {
        let deadSettings = "/var/folders/zz/T/subrouter-claude-settings-3294281412/settings.json"
        let request = resumeRequest(
            arguments: [capturedClaude, "--settings", deadSettings, "--model", "opus", "--settings=\(deadSettings)"],
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: marker,
                launchBoundMarker: marker
            )
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        #expect(
            invocation.arguments == ["sr", "claude", "proxy", "--resume", sessionID, "--model", "opus"],
            "\(invocation.arguments)"
        )
    }

    @Test("The subrouter program name in the marker is honoured, never rewritten to sr")
    func routedRestoreUsesTheMarkedLauncherProgram() throws {
        let subrouterMarker = "subrouter claude proxy --resume"
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: subrouterMarker,
                launchBoundMarker: subrouterMarker
            )
        )
        let planner = AgentRestorePlanner(isExecutableFile: { path in
            path == "/opt/homebrew/bin/subrouter" || path == "/shim/claude"
        })

        let invocation = try #require(planner.invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        #expect(invocation.arguments.starts(with: ["subrouter", "claude", "proxy", "--resume", sessionID]))
    }

    @Test("An inherited marker without the wrapper's launch-bound copy is not provenance")
    func inheritedMarkerAloneKeepsThePlainReplay() throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: marker,
                launchBoundMarker: nil
            )
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        expectPlainClaudeReplay(invocation, baseURL: localPoolBaseURL, "marker only")
    }

    @Test("A launch-bound copy without the marker, or one that disagrees, is not provenance")
    func disagreeingMarkersKeepThePlainReplay() throws {
        for (label, marker, bound) in [
            ("bound only", nil, marker),
            ("disagree", marker, "subrouter claude proxy --resume"),
            ("codex bound", marker, "sr codex resume"),
        ] as [(String, String?, String)] {
            let request = resumeRequest(
                environment: routedLaunchEnvironment(
                    baseURL: localPoolBaseURL,
                    marker: marker,
                    launchBoundMarker: bound
                )
            )
            let invocation = try #require(plannerWithSubrouterOnPath().invocation(
                for: request,
                ambientEnvironment: ambientEnvironment
            ))
            expectPlainClaudeReplay(invocation, baseURL: localPoolBaseURL, label)
        }
    }

    @Test(
        "Only the exact launcher command text is trusted",
        arguments: [
            "sr claude proxy --restore",
            "sr claude --resume",
            "sr claude proxy --resume --account evil",
            "/tmp/evil claude proxy --resume",
            "sr claude proxy --resume; rm -rf /",
            "cx claude proxy --resume",
            "SR CLAUDE PROXY --RESUME",
            "",
        ]
    )
    func unexpectedMarkerTextKeepsThePlainReplay(untrusted: String) throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: untrusted,
                launchBoundMarker: untrusted
            )
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        expectPlainClaudeReplay(invocation, baseURL: localPoolBaseURL, untrusted)
    }

    @Test("A local pool base URL alone is never treated as provenance")
    func localPoolBaseURLAloneKeepsThePlainReplay() throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(baseURL: localPoolBaseURL)
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        expectPlainClaudeReplay(invocation, baseURL: localPoolBaseURL, "base url only")
    }

    @Test("When sr cannot be resolved on the restore PATH the plain replay is kept")
    func missingLauncherOnPathKeepsThePlainReplay() throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: marker,
                launchBoundMarker: marker
            )
        )
        let planner = AgentRestorePlanner(isExecutableFile: { $0 == "/shim/claude" })

        let invocation = try #require(planner.invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        expectPlainClaudeReplay(invocation, baseURL: localPoolBaseURL, "sr missing")
    }

    @Test("A cmux launcher such as claude-teams is never rerouted through Subrouter")
    func cmuxLauncherIsNotRerouted() throws {
        let request = resumeRequest(
            arguments: ["cmux", "claude-teams", "--model", "opus"],
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: marker,
                launchBoundMarker: marker
            ),
            launcher: "claudeTeams"
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        #expect(invocation.arguments.contains("claude-teams"), "\(invocation.arguments)")
        #expect(invocation.arguments.contains("proxy") == false, "\(invocation.arguments)")
    }

    @Test("A direct plan replays the recorded argv untouched even with provenance")
    func directPlanReplaysRecordedArgv() throws {
        let request = resumeRequest(
            environment: routedLaunchEnvironment(
                baseURL: localPoolBaseURL,
                marker: marker,
                launchBoundMarker: marker
            ),
            mode: .direct
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ambientEnvironment
        ))

        #expect(invocation.arguments == [capturedClaude, "--model", "opus"])
        #expect(invocation.environment["ANTHROPIC_BASE_URL"] == localPoolBaseURL)
    }

    @Test("A codex record carrying the claude markers is not affected")
    func codexRecordIgnoresClaudeMarkers() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                arguments: ["codex"],
                workingDirectory: "/tmp/project",
                environment: [markerKey: marker, launchBoundMarkerKey: marker, "CODEX_HOME": "/tmp/codex-home"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(plannerWithSubrouterOnPath().invocation(
            for: request,
            ambientEnvironment: ["PATH": "/opt/homebrew/bin:/usr/bin"]
        ))

        #expect(invocation.arguments.first == "codex")
        #expect(invocation.arguments.contains("proxy") == false)
        #expect(invocation.environment["CODEX_HOME"] == "/tmp/codex-home")
        #expect(invocation.environment[markerKey] == nil)
    }
}

@Suite("Launch capture keeps the Subrouter claude resume markers, and only those")
struct SubrouterClaudeResumeMarkerCaptureTests {
    private let marker = "sr claude proxy --resume"
    private let markerKey = "SUBROUTER_CLAUDE_RESUME_COMMAND"
    private let launchBoundMarkerKey = "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND"

    @Test("An agreeing marker pair crosses the restore record boundary for claude")
    func agreeingMarkersAreCapturedForClaude() {
        let selected = AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
            from: [
                markerKey: marker,
                launchBoundMarkerKey: marker,
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415/v1",
                "ANTHROPIC_AUTH_TOKEN": "srt_secret_must_not_cross",
                "ANTHROPIC_CUSTOM_HEADERS": "X-Subrouter-Agent: claude",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-proxy/abc",
            ],
            kind: "claude"
        )

        #expect(selected == [
            markerKey: marker,
            launchBoundMarkerKey: marker,
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415/v1",
            "CLAUDE_CONFIG_DIR": "/tmp/claude-proxy/abc",
        ])
    }

    @Test("Markers that disagree, are not exact, or lack the launch-bound copy are dropped")
    func untrustedMarkersAreDropped() {
        for (label, environment) in [
            ("marker only", [markerKey: marker]),
            ("bound only", [launchBoundMarkerKey: marker]),
            ("disagree", [markerKey: marker, launchBoundMarkerKey: "subrouter claude proxy --resume"]),
            ("not exact", [markerKey: "sr claude proxy --restore", launchBoundMarkerKey: "sr claude proxy --restore"]),
            ("shell text", [markerKey: "sr claude proxy --resume; id", launchBoundMarkerKey: "sr claude proxy --resume; id"]),
        ] as [(String, [String: String])] {
            let selected = AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
                from: environment,
                kind: "claude"
            )
            #expect(selected.isEmpty, "\(label): \(selected)")
        }
    }

    @Test("The markers are not captured for other kinds nor for typed replay commands")
    func markersStayScopedToClaudeRestoreRecords() {
        let environment = [markerKey: marker, launchBoundMarkerKey: marker]

        #expect(AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(from: environment, kind: "codex").isEmpty)
        #expect(AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(from: environment, kind: nil).isEmpty)
        #expect(AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment, kind: "claude").isEmpty)
    }
}
