import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextUpdater
import Foundation

/// Reads this Mac's Tailscale address from the bundled `cmux host status --json`.
struct ServerTailnetSource: Sendable {
    /// The stdout of `host status --json`, nil when the CLI is missing or the run failed.
    let hostStatus: @Sendable () async -> Data?

    /// The bundled CLI's run, as the Add Device list makes it.
    static func app() -> ServerTailnetSource {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        return ServerTailnetSource(hostStatus: { await cli?.json(["host", "status", "--json"], deadline: .seconds(10), label: "host status") })
    }

    /// The first listed address, or nil.
    func address() async -> String? {
        guard let data = await hostStatus() else { return nil }
        return ServerTailnetAddress(hostStatus: data)?.value
    }
}
