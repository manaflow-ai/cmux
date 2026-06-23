import Testing
@testable import CMUXAgentLaunch

struct AgentLaunchCaptureTrustRegressionTests {
    @Test("Missing-launcher native process trust handles built-in executable aliases")
    func missingLauncherNativeProcessTrustsBuiltInExecutableAliases() {
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "hermes",
                arguments: ["/opt/homebrew/bin/hermes", "--provider", "custom", "--model", "gpt-5.5"],
                kind: "hermes-agent"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "acli",
                arguments: ["/usr/local/bin/acli", "rovodev", "run", "--restore", "rovo-session"],
                kind: "rovodev"
            )
        )
    }
}
