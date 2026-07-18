import Testing
@testable import CMUXAgentLaunch

@Suite("Cursor exec-a process arguments")
struct CursorExecAProcessArgumentsTests {
    @Test("Node runtime flags stay outside Cursor launch classification")
    func nodeRuntimeFlagsStayOutsideCursorLaunchClassification() {
        let interactive = [
            "/Users/alice/.local/bin/cursor-agent",
            "--use-system-ca",
            "/Users/alice/.local/share/cursor-agent/versions/current/index.js",
        ]

        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: interactive,
                kind: "cursor"
            ) == []
        )
        #expect(
            AgentLaunchModeClassifier().processMode(
                processName: "node",
                arguments: interactive,
                kind: "cursor"
            ) == .interactive
        )

        let printMode = interactive + ["--print", "reply exactly once"]
        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: printMode,
                kind: "cursor"
            ) == ["--print", "reply exactly once"]
        )
        #expect(
            AgentLaunchModeClassifier().processMode(
                processName: "node",
                arguments: printMode,
                kind: "cursor"
            ) == .oneShot
        )

        let shortPrintMode = interactive + ["-p", "reply exactly once"]
        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: shortPrintMode,
                kind: "cursor"
            ) == ["-p", "reply exactly once"]
        )
        #expect(
            AgentLaunchModeClassifier().processMode(
                processName: "node",
                arguments: shortPrintMode,
                kind: "cursor"
            ) == .oneShot
        )
    }

    @Test("Generic Node entrypoints cannot establish Cursor identity")
    func genericNodeEntrypointsCannotEstablishCursorIdentity() {
        let unrelated = [
            "/Users/alice/bin/unrelated-tool",
            "--use-system-ca",
            "/Users/alice/project/index.js",
            "--print",
            "prompt",
        ]

        #expect(
            !AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: unrelated,
                kind: "cursor"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: unrelated,
                kind: "cursor"
            ) == nil
        )
    }
}
