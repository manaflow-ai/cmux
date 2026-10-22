import CmuxNextAgentPane
import CmuxNextControl
import Foundation

/// `agent.acpmux` (#23026): where this app's own acpmux listens, the one its agent chat tabs
/// use (``AcpmuxEnvironment/resolve(build:bundledBinDirectory:environment:launchEnvironment:)``,
/// as `AgentTabStore` resolves it). `cmux agents chat new` starts a chat there, so a caller
/// whose own acpmux is another one (a Chief turn runs in its home's) starts a chat the app shows
/// as an ordinary chat, as New Agent Chat and a first message do, not a subagent. Read only:
/// `{socket_path, home}`, or null when this build has no acpmux.
enum AgentAcpmuxControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("agent.acpmux") { [weak services] _ in
                guard let services else { return .value(.null) }
                let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
                guard let acpmux = AcpmuxEnvironment.resolve(build: services.environment.build, bundledBinDirectory: bin,
                                                             environment: ProcessInfo.processInfo.environment) else {
                    return .value(.null)
                }
                return .value(["socket_path": .string(acpmux.socketPath), "home": .string(acpmux.home.path)])
            },
        ]
    }
}
