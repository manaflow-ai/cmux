import CmuxNextAgentPane
import CmuxNextControl
import Foundation

/// The agent tabs' pane page and acpmux host (outside AgentTabStore, which is at its size limit).
@MainActor struct AgentTabPaneSource {
    /// The agent pane page and its acpmux host. Release loads only the
    /// bundled page; the dev server is for Debug and tagged builds
    /// (webviews/src/agent-session/acpmux/README.md). The page never opens a
    /// socket to acpmux: the host does (AgentPaneTransport), always with the
    /// bundled pane's origin, so even a dev server page reaches LocalApp and
    /// the app starts the daemon with no dev origin and no `--dev`
    /// (``paneEnvironment(tag:bundledBinDirectory:environment:launch:isExecutable:)``). Only the
    /// browser dev slot, with no host, still needs both (dev-slot.sh).
    static func resolvePane(tag: String?, environment: [String: String], showcase: Bool)
        -> (source: AgentPaneSource?, host: any AgentPaneHostProviding) {
        #if DEBUG
        let allowsDevServer = true
        #else
        let allowsDevServer = false
        #endif
        let source = AgentPaneSource.resolve(
            environment: environment, bundledPage: AgentPaneView.bundledPage, allowsDevServer: allowsDevServer
        )
        if showcase || environment["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" {
            return (source, MockAgentPaneHost())
        }
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let computerUse = ComputerUseHelperDaemon.shared
        // The helper v2 endpoint directory goes to every acpmux daemon this
        // app spawns, whatever the driver: it is constant for this app build,
        // so a daemon started while the driver is legacy finds the v2
        // endpoint after a switch to upstream. acpmux uses v2 only while
        // endpoint.json exists there (ComputerUseHelperV2).
        let upstreamEnvironment = ComputerUseHelperV2.childEnvironment(directory: computerUse.upstream.directory)
        let launch = LaunchIdentity.current()
        let resolve: @Sendable () -> AcpmuxEnvironment? = {
            paneEnvironment(tag: tag, bundledBinDirectory: bin, environment: environment, launch: launch).map {
                var resolved = $0
                resolved.childEnvironment.merge(upstreamEnvironment) { $1 }
                return resolved
            }
        }
        computerUse.upstream.acpmux = { resolve().map { ($0.executable, $0.socketPath) } }
        let upstream = computerUse.upstream
        let host = AcpmuxHost(resolve: resolve,
                              computerUse: { computerUse.childEnvironment },
                              daemonReady: { socket in await upstream.registerAcpmuxDaemon(acpmuxSocket: socket) })
        return (source, host)
    }

    /// The daemon the app starts, in every build configuration and for every page source: no
    /// `--allow-dev-origin` and no `--dev` (the host's socket carries the bundled pane's origin).
    /// Its agents get what this app's terminals get for `cmux` (cx-c6xdh): the control socket
    /// naming this app (`launch`) and the bundled CLI, which acpmux puts first on their `PATH`.
    nonisolated static func paneEnvironment(
        tag: String?, bundledBinDirectory: URL?, environment: [String: String], launch: LaunchIdentity = .current(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AcpmuxEnvironment? {
        guard var resolved = AcpmuxEnvironment.resolve(
            tag: tag, bundledBinDirectory: bundledBinDirectory, environment: environment, isExecutable: isExecutable
        ) else { return nil }
        resolved.childEnvironment.merge(launch.terminalEnvironment) { $1 }
        if let cli = bundledBinDirectory?.appendingPathComponent("cmux").path, isExecutable(cli) {
            resolved.childEnvironment["CMUX_BUNDLED_CLI_PATH"] = cli
        }
        return resolved
    }
}
