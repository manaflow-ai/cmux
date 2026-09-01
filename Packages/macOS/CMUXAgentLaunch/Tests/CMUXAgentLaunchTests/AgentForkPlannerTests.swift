import CMUXAgentLaunch
import Testing

@Suite("AgentForkPlanner")
struct AgentForkPlannerTests {
    @Test("Custom fork templates render through the package boundary")
    func customForkTemplateRendersStructuredArguments() throws {
        let request = AgentForkRequest(
            kind: "custom-agent",
            checkpointID: "checkpoint",
            launchCommand: AgentLaunchCommand(
                executablePath: "/opt/bin/agent",
                arguments: ["/opt/bin/agent", "--model", "fast"]
            ),
            workingDirectory: "/tmp/fork repo",
            isCustomKind: true,
            customTemplate: AgentForkRequest.CustomTemplate(
                command: "{{executable}} --branch {{sessionId}} --cwd {{cwd}}",
                defaultExecutable: "custom-agent"
            )
        )

        #expect(request.forkArguments() == [
            "/opt/bin/agent",
            "--branch",
            "checkpoint",
            "--cwd",
            "/tmp/fork repo",
        ])
    }

    @Test("Custom templates preserve single-quoted backslashes")
    func customTemplatePreservesSingleQuotedBackslashes() throws {
        let renderer = AgentLaunchTemplateRenderer()
        #expect(renderer.arguments(
            template: "agent '{{sessionId}}\\path'",
            executable: "agent",
            sessionID: "session",
            workingDirectory: nil,
            sessionDirectory: nil
        ) == ["agent", "session\\path"])
    }

    @Test("Custom templates reject unterminated quotes")
    func customTemplateRejectsUnterminatedQuotes() {
        let renderer = AgentLaunchTemplateRenderer()
        #expect(renderer.arguments(
            template: "agent '{{sessionId}}",
            executable: "agent",
            sessionID: "session",
            workingDirectory: nil,
            sessionDirectory: nil
        ) == nil)
    }

    @Test("Custom templates retain quoted whitespace and empty words")
    func customTemplateRetainsQuotedWhitespaceAndEmptyWords() throws {
        let renderer = AgentLaunchTemplateRenderer()
        #expect(renderer.arguments(
            template: "agent '  {{sessionId}}  ' '' tail",
            executable: "agent",
            sessionID: "session",
            workingDirectory: nil,
            sessionDirectory: nil
        ) == ["agent", "  session  ", "", "tail"])
    }

    @Test("Custom templates retain ordinary double-quoted backslashes")
    func customTemplateRetainsDoubleQuotedOrdinaryBackslashes() throws {
        let renderer = AgentLaunchTemplateRenderer()
        #expect(renderer.arguments(
            template: #"agent "a\q""#,
            executable: "agent",
            sessionID: "session",
            workingDirectory: nil,
            sessionDirectory: nil
        ) == ["agent", "a\\q"])
    }

    @Test("Uses prepared fork argv with restore environment policy")
    func preparedForkArgumentsStayStructured() throws {
        let checkpointID = "fork-session"
        let planner = AgentRestorePlanner(isExecutableFile: { _ in false })
        let request = AgentRestoreRequest(
            mode: .forkAgent,
            kind: "custom-agent",
            checkpointID: checkpointID,
            source: "session-snapshot",
            workingDirectory: "/tmp/fork repo",
            environment: ["CODEX_HOME": "/tmp/codex home"],
            launchCommand: AgentLaunchCommand(
                arguments: ["custom-agent"],
                workingDirectory: "/tmp/fork repo",
                environment: ["CODEX_HOME": "/tmp/codex home"]
            ),
            preparedArguments: ["/opt/custom-agent", "--fork", checkpointID],
            preparedArgumentsWorkingDirectory: "/tmp/fork repo",
            observedPermissionMode: nil
        )

        let invocation = try #require(
            planner.invocation(
                for: request,
                ambientEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        )
        #expect(invocation.arguments == ["/opt/custom-agent", "--fork", checkpointID])
        #expect(invocation.workingDirectory == "/tmp/fork repo")
        #expect(invocation.environment["CODEX_HOME"] == "/tmp/codex home")
    }

    @Test("Native Claude fork argv is derived when no prepared argv is present")
    func nativeClaudeForkArgumentsAreDerived() throws {
        let planner = AgentRestorePlanner(isExecutableFile: { _ in false })
        let request = AgentRestoreRequest(
            mode: .forkAgent,
            kind: "claude",
            checkpointID: "SID",
            source: "session-snapshot",
            workingDirectory: nil,
            environment: [:],
            launchCommand: AgentLaunchCommand(
                arguments: ["/opt/bin/claude", "--model", "sonnet"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        let invocation = try #require(
            planner.invocation(for: request, ambientEnvironment: ["PATH": "/usr/bin:/bin"])
        )
        #expect(invocation.arguments == ["claude", "--resume", "SID", "--fork-session", "--model", "sonnet"])
    }
}
