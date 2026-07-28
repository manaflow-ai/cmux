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

    private func kernProcArgs(
        arguments: [String],
        environmentEntries: [String]
    ) -> [UInt8] {
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        appendCString(arguments.first ?? "", to: &bytes)
        bytes.append(0)
        for argument in arguments {
            appendCString(argument, to: &bytes)
        }
        for entry in environmentEntries {
            appendCString(entry, to: &bytes)
        }
        return bytes
    }

    private func appendCString(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
    }
}
