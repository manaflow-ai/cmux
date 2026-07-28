import Testing
@testable import CMUXAgentLaunch

@Suite("Agent process arguments parser")
struct AgentProcessArgumentsParserTests {
    @Test func preservesEmptyArgumentElements() throws {
        let bytes = kernProcArgs(
            arguments: ["codex", "", "resume"],
            environmentEntries: ["PWD=/tmp/project"]
        )

        let process = try #require(
            AgentProcessArgumentsParser().argumentsAndEnvironment(
                fromKernProcArgs: bytes
            )
        )

        #expect(process.arguments == ["codex", "", "resume"])
        #expect(process.environment["PWD"] == "/tmp/project")
    }

    @Test func extractsCandidateMetadataWithoutFullDecoding() throws {
        let bytes = kernProcArgs(
            arguments: [
                "/usr/bin/python3",
                "/opt/tools/claude-custom",
                "--Resume",
            ],
            environmentEntries: [
                "PWD=/tmp/pwd",
                "CMUX_AGENT_LAUNCH_CWD=/tmp/launch",
                "CMUX_AGENT_LAUNCH_KIND=claude",
                "CMUX_AGENT_LAUNCH_EXECUTABLE=/opt/tools/claude-custom",
            ]
        )

        let metadata = try #require(
            AgentProcessArgumentsParser().filterMetadata(
                fromKernProcArgs: bytes,
                normalizedArgumentNeedles: [Array("--resume".utf8)]
            )
        )

        #expect(metadata.projectWorkingDirectory == "/tmp/launch")
        #expect(metadata.argumentsContainAnyNeedle)
        #expect(metadata.agentLaunchKind == "claude")
        #expect(metadata.agentLaunchExecutable == "/opt/tools/claude-custom")
        #expect(metadata.executableArgument == "/usr/bin/python3")
        #expect(metadata.firstArgumentAfterExecutable == "/opt/tools/claude-custom")
    }

    @Test func rejectsMalformedBuffers() {
        let parser = AgentProcessArgumentsParser()

        #expect(parser.kernProcArgsBytes(for: 0) == nil)
        #expect(parser.argumentsAndEnvironment(fromKernProcArgs: [1, 2, 3]) == nil)
        #expect(
            parser.filterMetadata(
                fromKernProcArgs: [1, 2, 3],
                normalizedArgumentNeedles: []
            ) == nil
        )
    }

    @Test func rejectsUnterminatedCStringEntries() {
        let parser = AgentProcessArgumentsParser()

        var unterminatedArgument = kernProcArgs(
            arguments: ["codex"],
            environmentEntries: []
        )
        unterminatedArgument.removeLast()
        #expect(
            parser.argumentsAndEnvironment(
                fromKernProcArgs: unterminatedArgument
            ) == nil
        )
        #expect(
            parser.filterMetadata(
                fromKernProcArgs: unterminatedArgument,
                normalizedArgumentNeedles: []
            ) == nil
        )

        var unterminatedEnvironment = kernProcArgs(
            arguments: ["codex"],
            environmentEntries: ["PWD=/tmp/project"]
        )
        unterminatedEnvironment.removeLast()
        #expect(
            parser.argumentsAndEnvironment(
                fromKernProcArgs: unterminatedEnvironment
            ) == nil
        )
        #expect(
            parser.filterMetadata(
                fromKernProcArgs: unterminatedEnvironment,
                normalizedArgumentNeedles: []
            ) == nil
        )
    }
}
