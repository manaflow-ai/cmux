import CmuxNextAgentActivity
@testable import CmuxNextApp
@testable import CmuxNextComputerUse
import CmuxNextOnboarding
import Testing

/// The Computer Use helper (a service) hands out its socket and tokens as plain values; the App
/// keys them as the Agent Activity reader reads them. An acpmux child gets the socket and the
/// agent token only: the host token, which user operations need, never leaves this app.
@MainActor struct ComputerUseHelperEndpointTests {
    @Test func anAcpmuxChildGetsTheSocketAndTheAgentTokenButNeverTheHostToken() {
        let endpoint = ComputerUseHelperDaemon.Endpoint(socketPath: "/tmp/cua.sock", agentToken: "agent", hostToken: "host")
        let environment = ComputerUseSetup.childEnvironment { endpoint }()
        #expect(environment == [
            AgentActivitySocketSource.Configuration.socketEnvironmentKey: "/tmp/cua.sock",
            AgentActivitySocketSource.Configuration.authTokenEnvironmentKey: "agent",
        ])
        #expect(!environment.values.contains("host"))
    }

    @Test func aChildGetsNothingWhileTheHelperIsOff() {
        #expect(ComputerUseSetup.childEnvironment { nil }().isEmpty)
    }

    @Test func theAppsOwnReadersGetTheSocketAndBothTokens() throws {
        let endpoint = ComputerUseHelperDaemon.Endpoint(socketPath: "/tmp/cua.sock", agentToken: "agent", hostToken: "host")
        let configuration = try #require(ComputerUseSetup.readerConfiguration(endpoint))
        #expect(configuration.socketPath == "/tmp/cua.sock")
        #expect(configuration.authToken == "agent")
        #expect(configuration.hostAuthToken == "host")
    }

    @Test func theAppsOwnReadersGetNoConfigurationWhileTheHelperIsOff() {
        #expect(ComputerUseSetup.readerConfiguration(nil) == nil)
    }

    /// The Privacy & Security lists the grant actions open.
    @Test func eachGrantOpensItsPrivacyList() {
        #expect(ComputerUsePermissionPane.accessibility.settingsURL?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(ComputerUsePermissionPane.screenRecording.settingsURL?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
