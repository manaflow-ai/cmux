import CmuxNextAgentPane
import Foundation

extension AgentTabStore {
    /// The agent pane page and its acpmux host. Release loads only the
    /// bundled page; the dev server is for Debug and tagged builds
    /// (webviews/src/agent-session/acpmux/README.md). The page never opens a
    /// socket to acpmux: the host does (AgentPaneTransport), always with the
    /// bundled pane's origin, so even a dev server page reaches LocalApp and
    /// the app starts the daemon with no dev origin and no `--dev`
    /// (``paneEnvironment(tag:bundledBinDirectory:environment:)``). Only the
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
        let host = AcpmuxHost(resolve: { paneEnvironment(tag: tag, bundledBinDirectory: bin, environment: environment) },
                              computerUse: { computerUse.childEnvironment })
        return (source, host)
    }

    /// The daemon the app starts, in every build configuration and for every page source: no
    /// `--allow-dev-origin` and no `--dev` (the host's socket carries the bundled pane's origin).
    nonisolated static func paneEnvironment(tag: String?, bundledBinDirectory: URL?, environment: [String: String]) -> AcpmuxEnvironment? {
        AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: bundledBinDirectory, environment: environment)
    }
}
