import CmuxNextAgentPane
import Foundation

extension AgentTabStore {
    /// The agent pane page and its acpmux host. Release loads only the
    /// bundled page; the dev server is for Debug and tagged builds
    /// (webviews/src/agent-session/acpmux/README.md). A dev server page has
    /// its own origin, which acpmux accepts only when this (Debug) app starts
    /// it with `--allow-dev-origin` (identity.md section 4).
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
        let devOrigin = source?.devServerOrigin
        let host = AcpmuxHost {
            AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: bin, environment: environment)?
                .allowingDevOrigin(devOrigin)
        }
        return (source, host)
    }
}
