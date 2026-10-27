import Foundation

/// The automatic-restore connection: use the running daemon as it is, or start a missing one.
/// It never hands off a different build, heals a stopped Chief, or enrolls its person key.
nonisolated struct AcpmuxLaunchConnection {
    let environment: AcpmuxEnvironment
    let mayStart: Bool

    func prepare() async throws {
        try Task.checkCancellation()
        do {
            try await checkHome()
        } catch AcpmuxStatusClient.Failure.unreachable where mayStart {
            do {
                _ = try await AcpmuxDaemonLauncher.launch(environment)
            } catch AcpmuxDaemonLauncher.Failure.exited {
                // A concurrent pane or Chief won the daemon lock. Use its daemon without changing it.
                try await checkHome()
            }
        }
        try Task.checkCancellation()
    }

    private func checkHome() async throws {
        let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
        guard status.serves(home: environment.home) else {
            throw AcpmuxStatusClient.Failure.otherHome(status.home ?? "")
        }
    }
}
