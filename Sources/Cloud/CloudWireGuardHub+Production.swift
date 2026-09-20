import Foundation

extension CloudWireGuardHub {
    /// The production hub for the bundled client, writing under `~/.cmuxterm/wireguard`.
    static func production(clientURL: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> CloudWireGuardHub {
        let manager = VMTunnelManager(home: home, purpose: .terminal)
        let configuration = Configuration(
            enroll: {
                if let config = manager.writtenConfig() {
                    return Enrollment(configPath: manager.configURL.path, routes: VMTunnelManager.allowedIPs(in: config))
                }
                let client = await MainActor.run { VMClient.shared }
                guard let client else {
                    throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).")
                }
                let state = try await manager.enroll(client: client)
                return Enrollment(configPath: state.configPath, routes: state.endpoint.routes)
            },
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
