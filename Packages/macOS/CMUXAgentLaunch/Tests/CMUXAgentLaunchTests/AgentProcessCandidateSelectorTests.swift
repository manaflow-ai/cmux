import Testing
@testable import CMUXAgentLaunch

@Suite("Agent process candidate selector")
struct AgentProcessCandidateSelectorTests {
    @Test func selectsOnlyProcessesAllowedByBuiltInPolicy() {
        let processes = [
            candidate(processID: 1, name: "zsh", isForeground: true),
            candidate(processID: 2, name: "node", shouldInspectArguments: true),
            candidate(processID: 3, name: "pi"),
            candidate(processID: 4, name: "worker", path: "/opt/bin/codex"),
            candidate(processID: 5, name: "cmux"),
            candidate(processID: 6, name: "zsh"),
        ]
        let selector = AgentProcessCandidateSelector(
            processes: processes,
            policy: policy(
                rules: [
                    AgentProcessDetectionRule(
                        processName: "pi",
                        processNames: [],
                        argvContains: [],
                        alternateProcessNames: [],
                        alternateArgvContains: [],
                        alternateArgvContainsAny: []
                    ),
                ],
                builtInAgentBasenames: ["codex"]
            )
        )

        #expect(selector.processIDs == [1, 2, 3, 4, 5])
    }

    @Test func customPolicyPreservesExhaustiveSelection() {
        let processes = [
            candidate(processID: 10, name: "zsh"),
            candidate(processID: 11, name: "unknown-worker"),
        ]
        let selector = AgentProcessCandidateSelector(
            processes: processes,
            policy: policy(usesBuiltInFastPath: false)
        )

        #expect(selector.processIDs == [10, 11])
    }

    @Test func scanDecodesOnlyRawArgumentMatches() {
        let matchingProcess = candidate(processID: 20, name: "zsh")
        let rejectedProcess = candidate(processID: 21, name: "zsh")
        let bytesByProcessID = [
            20: kernProcArgs(
                arguments: ["/bin/zsh", "/opt/custom-agent"],
                environmentEntries: []
            ),
            21: kernProcArgs(
                arguments: ["/bin/zsh"],
                environmentEntries: []
            ),
        ]
        let selector = AgentProcessCandidateSelector(
            processes: [matchingProcess, rejectedProcess],
            policy: policy(
                rules: [
                    AgentProcessDetectionRule(
                        processName: nil,
                        processNames: [],
                        argvContains: ["custom-agent"],
                        alternateProcessNames: [],
                        alternateArgvContains: [],
                        alternateArgvContainsAny: []
                    ),
                ]
            )
        )
        var rawFetchCount = 0
        var fullDecodeCount = 0
        var scan = AgentProcessArgumentScan(
            processes: [matchingProcess, rejectedProcess],
            selector: selector,
            injectedArgumentsProvider: nil,
            processArgumentBytesProvider: { processID in
                rawFetchCount += 1
                return bytesByProcessID[processID]
            },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return AgentProcessArgumentsParser().argumentsAndEnvironment(
                    fromKernProcArgs: bytes
                )
            },
            additionalMetadataRequiresFullDecode: { _ in false }
        )

        #expect(scan.candidateProcessIDs == [20])
        #expect(scan.arguments(for: 21) == nil)
        #expect(scan.arguments(for: 20)?.arguments == ["/bin/zsh", "/opt/custom-agent"])
        #expect(scan.arguments(for: 20)?.arguments == ["/bin/zsh", "/opt/custom-agent"])
        #expect(rawFetchCount == 2)
        #expect(fullDecodeCount == 1)
    }

    @Test func recordedLaunchMetadataAdmitsExecutableFromArgvZeroOrOne() throws {
        let selector = AgentProcessCandidateSelector(
            processes: [],
            policy: policy()
        )
        let recordedExecutable = "/opt/tools/claude-custom"
        let argumentVectors = [
            [recordedExecutable],
            ["/usr/bin/python3", recordedExecutable],
        ]

        for arguments in argumentVectors {
            let metadata = try #require(selector.rawMetadata(
                fromKernProcArgs: kernProcArgs(
                    arguments: arguments,
                    environmentEntries: [
                        "CMUX_AGENT_LAUNCH_KIND=claude",
                        "CMUX_AGENT_LAUNCH_EXECUTABLE=\(recordedExecutable)",
                    ]
                )
            ))

            #expect(selector.rawMetadataMayRequireFullDecode(
                metadata,
                process: candidate(
                    processID: 30,
                    name: "agent-shim",
                    path: "/opt/tools/agent-shim"
                )
            ))
        }
    }

    private func candidate(
        processID: Int,
        name: String,
        path: String? = nil,
        isForeground: Bool = false,
        shouldInspectArguments: Bool = false
    ) -> AgentProcessCandidate {
        AgentProcessCandidate(
            processID: processID,
            name: name,
            path: path,
            isTerminalForegroundProcessGroup: isForeground,
            shouldInspectArguments: shouldInspectArguments
        )
    }

    private func policy(
        usesBuiltInFastPath: Bool = true,
        rules: [AgentProcessDetectionRule] = [],
        builtInAgentBasenames: Set<String> = []
    ) -> AgentProcessCandidatePolicy {
        AgentProcessCandidatePolicy(
            usesBuiltInFastPath: usesBuiltInFastPath,
            detectionRules: rules,
            builtInAgentBasenames: builtInAgentBasenames,
            wrapperBasenames: ["cmux"]
        )
    }
}
