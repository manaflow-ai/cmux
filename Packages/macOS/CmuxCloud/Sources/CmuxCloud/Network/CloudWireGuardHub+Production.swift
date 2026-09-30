import CmuxAuthRuntime
import Foundation

extension CloudWireGuardHub {
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private static func freshEnrollment(
        manager: VMTunnelManager,
        allowWhenCloudDisabled: Bool = false,
        expectedTeamScope: AuthenticatedTeamScope? = nil
    ) async throws -> Enrollment {
        let client = await MainActor.run { VMClient.shared }
        guard let client else { throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).") }
        let state = try await manager.enroll(
            client: client,
            allowWhenCloudDisabled: allowWhenCloudDisabled,
            expectedTeamScope: expectedTeamScope
        )
        return Enrollment(configPath: state.configPath, routes: VMTunnelManager.allowedIPs(in: state.completedConfig))
    }

    /// The production hub for the bundled client, writing under `~/.cmuxterm/wireguard`.
    public static func production(clientURL: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> CloudWireGuardHub {
        let manager = VMTunnelManager(home: home, purpose: .terminal)
        let configuration = Configuration(
            enroll: {
                if let config = manager.writtenConfig() {
                    return Enrollment(configPath: manager.configURL.path, routes: VMTunnelManager.allowedIPs(in: config))
                }
                return try await CloudWireGuardHub.freshEnrollment(manager: manager)
            },
            enrollWhenCloudDisabled: { expectedTeamScope in
                try await CloudWireGuardHub.freshEnrollment(
                    manager: manager,
                    allowWhenCloudDisabled: true,
                    expectedTeamScope: expectedTeamScope
                )
            },
            refreshEnrollment: { try await CloudWireGuardHub.freshEnrollment(manager: manager) },
            clientURL: clientURL,
            socketURL: manager.stateDir.appendingPathComponent("hub-\(getpid()).sock", isDirectory: false),
            spawner: CloudWireGuardHubProcessSpawner(),
            waitUntilReady: { socketPath in
                try await CloudWireGuardHubSocketReadiness.wait(socketPath: socketPath, timeout: .seconds(45))
            },
            sleep: { duration in try await ContinuousClock().sleep(for: duration) },
            restartBackoff: Configuration.defaultRestartBackoff,
            idleGrace: Configuration.defaultIdleGrace
        )
        return CloudWireGuardHub(configuration: configuration)
    }
}
