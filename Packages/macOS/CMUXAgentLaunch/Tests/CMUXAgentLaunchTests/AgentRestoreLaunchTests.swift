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

    @Test func invalidOwnershipCannotCreateRestoreLaunch() {
        #expect(AgentRestoreLaunch(kind: "gemini", sessionID: sessionID) == nil)
        #expect(AgentRestoreLaunch(kind: "codex", sessionID: "not-a-session-id") == nil)
        #expect(AgentRestoreLaunch(kind: nil, sessionID: sessionID) == nil)
        #expect(AgentRestoreLaunch(kind: "claude", sessionID: nil) == nil)
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
}
