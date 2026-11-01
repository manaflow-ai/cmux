import Darwin
import Foundation
import Testing
import CmuxNextAgentActivity
import CmuxNextSettings
@testable import CmuxNextComputerUse

/// Records helper starts instead of launching an app.
@MainActor
private final class RecordingHelperLauncher: ComputerUseHelperLaunching {
    private(set) var started: [[String: String]] = []
    private(set) var stopped: [pid_t] = []

    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
        started.append(environment)
        return pid_t(40_000 + started.count)
    }

    func terminate(_ pid: pid_t) {
        stopped.append(pid)
    }

    func isRunning(_ pid: pid_t) -> Bool { true }

    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void { {} }
}

/// An agent's computer use server gets the helper's socket and agent token
/// once, when its chat starts (acpmux `agent_tools`). The token was new for
/// each helper start and was published only while the helper ran, so a chat
/// started before the person turned Computer Use on (the first-run path: the
/// agent asks, the person allows) or before a helper restart kept a missing
/// or stale endpoint until a new chat.
@MainActor
struct ComputerUseEndpointTests {
    /// `upstreamInBuild`: whether the helper v2 is in this build. The SwiftPM test bundle embeds
    /// none, so without a fixture driver "upstream" falls back to the legacy helper.
    private static func daemon(_ launcher: RecordingHelperLauncher, upstreamInBuild: Bool = false) -> ComputerUseHelperDaemon {
        let root = FileManager.default.temporaryDirectory.appending(path: "cua-endpoint-\(UUID().uuidString.prefix(8))")
        let embedded: URL? = upstreamInBuild ? URL(fileURLWithPath: "/test/cmux Computer Use (dev).app") : nil
        let upstream = ComputerUseHelperV2(directory: root.appending(path: "v2").path, helperApp: { embedded },
                                           staging: .passing(root: root))
        return ComputerUseHelperDaemon(identity: CuaHelperIdentity(isSigned: { _ in true }),
                                       candidates: { [root.appending(path: "missing/cmux Computer Use.app")] },
                                       launcher: launcher, staging: .passing(root: root),
                                       socketPath: root.appending(path: "s/cua.sock").path,
                                       stateDirectory: root.appending(path: "state"), upstream: upstream)
    }

    private static func settings(enabled: Bool, driver: ComputerUseDriver = .legacy) -> ComputerUseSettings {
        var settings = ComputerUseSettings()
        settings.enabled = enabled
        settings.driver = driver
        return settings
    }

    @Test func aChatStartedWhileOffReachesTheHelperThatStartsLater() async throws {
        let launcher = RecordingHelperLauncher()
        let daemon = Self.daemon(launcher)
        await daemon.apply(Self.settings(enabled: false), disabledByPolicy: false)
        let beforeSetup = daemon.childEnvironment
        #expect(beforeSetup["CMUX_NEXT_CUA_SOCKET"] == daemon.socketPath)
        let token = try #require(beforeSetup["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"])
        #expect(launcher.started.isEmpty, "off starts no helper")

        await daemon.apply(Self.settings(enabled: true), disabledByPolicy: false)
        let started = try #require(launcher.started.first)
        #expect(started["CMUX_CUA_SOCKET_AUTH_TOKEN"] == token, "the helper serves the token the chat already has")
        #expect(daemon.childEnvironment == beforeSetup)
    }

    /// A pane can connect before settings load; it must not enroll an empty endpoint.
    @Test func theEndpointIsPublishedFromLaunch() {
        let daemon = Self.daemon(RecordingHelperLauncher())
        #expect(daemon.childEnvironment["CMUX_NEXT_CUA_SOCKET"] == daemon.socketPath)
        #expect(daemon.childEnvironment["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"]?.isEmpty == false)
    }

    @Test func aHelperRestartServesTheSameAgentToken() async throws {
        let launcher = RecordingHelperLauncher()
        let daemon = Self.daemon(launcher)
        await daemon.apply(Self.settings(enabled: true), disabledByPolicy: false)
        await daemon.restartLegacy()
        #expect(launcher.stopped == [40_001])
        #expect(daemon.state == .running(40_002))
        try #require(launcher.started.count == 2)
        #expect(launcher.started[0]["CMUX_CUA_SOCKET_AUTH_TOKEN"] == launcher.started[1]["CMUX_CUA_SOCKET_AUTH_TOKEN"])
        #expect(launcher.started[0]["CMUX_CUA_SOCKET_HOST_AUTH_TOKEN"] != launcher.started[1]["CMUX_CUA_SOCKET_HOST_AUTH_TOKEN"],
                "the host token stays one per start")
        #expect(daemon.childEnvironment["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"] == launcher.started[1]["CMUX_CUA_SOCKET_AUTH_TOKEN"])
        #expect(Set(daemon.childEnvironment.keys) == ["CMUX_NEXT_CUA_SOCKET", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"],
                "the host token never leaves the app")
    }

    @Test func policyAndTheHelperV2PublishNoEndpoint() async {
        let launcher = RecordingHelperLauncher()
        let daemon = Self.daemon(launcher, upstreamInBuild: true)
        await daemon.apply(Self.settings(enabled: true), disabledByPolicy: true)
        #expect(daemon.childEnvironment.isEmpty)
        #expect(launcher.started.isEmpty)
        await daemon.apply(Self.settings(enabled: false, driver: .upstream), disabledByPolicy: false)
        #expect(daemon.childEnvironment.isEmpty)
    }

    /// Driver "upstream" in a build without the helper v2 runs the legacy helper, so its endpoint
    /// stays published, off too: a chat started before Computer Use is turned on reaches it later.
    @Test func anUpstreamFallbackPublishesTheLegacyEndpoint() async throws {
        let launcher = RecordingHelperLauncher()
        let daemon = Self.daemon(launcher)
        await daemon.apply(Self.settings(enabled: false, driver: .upstream), disabledByPolicy: false)
        #expect(daemon.childEnvironment["CMUX_NEXT_CUA_SOCKET"] == daemon.socketPath)
        let token = try #require(daemon.childEnvironment["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"])
        #expect(launcher.started.isEmpty, "off starts no helper")
        await daemon.apply(Self.settings(enabled: true, driver: .upstream), disabledByPolicy: false)
        #expect(launcher.started.first?["CMUX_CUA_SOCKET_AUTH_TOKEN"] == token)
        await daemon.apply(Self.settings(enabled: true, driver: .upstream), disabledByPolicy: true)
        #expect(daemon.childEnvironment.isEmpty, "policy still withdraws it")
    }

    @Test func quittingWithdrawsTheEndpoint() async {
        let launcher = RecordingHelperLauncher()
        let daemon = Self.daemon(launcher)
        await daemon.apply(Self.settings(enabled: true), disabledByPolicy: false)
        daemon.applicationWillTerminate()
        #expect(daemon.childEnvironment.isEmpty)
        #expect(launcher.stopped.count == 1)
    }
}
