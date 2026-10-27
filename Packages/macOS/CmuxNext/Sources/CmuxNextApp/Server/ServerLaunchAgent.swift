import CmuxNextServer
import CmuxNextWakeups
import Foundation

/// Keeps the Mac's server running when the app quits (plans/cmux-next/server.md 4.3):
/// a launchd agent registered with `SMAppService.agent` from the plist the app
/// bundle carries in `Contents/Library/LaunchAgents` (written by
/// scripts/cmux-next/bundle-server-helper.sh, label `<bundle id>.server`). The
/// agent runs the bundled `cmux host run` with launchd `ProcessType` `Interactive`:
/// every terminal key and frame passes through it, so it is never `Background`
/// (process roles in plans/cmux-next/threading-model.md). Builds without the bundled CLI do
/// not carry the plist. Registration also needs the Debug Settings switch
/// `server.agent.allowRegister` (off by default) until the bundled CLI ships
/// `cmux host run`. `ServerStopServing` unregisters it, switch or not.
/// This is the only place that registers the agent.
struct ServerLaunchAgent {
    static let plistName = "com.cmux.server.plist"

    enum Failure: Error, Equatable {
        /// The bundle has no agent plist (the server software is not in this build).
        case notInBuild
        /// The opt-in switch is off: the server software is not ready yet.
        case notReady
        /// The user must allow the agent in System Settings > Login Items.
        case requiresApproval
        case failed(String)
    }

    var isBundled: @MainActor () -> Bool
    var allowRegister: @MainActor () -> Bool
    var service: ServerServiceRegistration

    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(plistName)").path)
    }

    static func app(work: BackgroundWork) -> ServerLaunchAgent {
        ServerLaunchAgent(isBundled: { Self.isBundled }, allowRegister: { ServerTunables.agentAllowRegister.value },
                          service: .agent(work: work))
    }

    /// Registers the agent; its launchd calls run on the system lane. Idempotent: an enabled agent stays enabled.
    func register() async throws(Failure) {
        guard isBundled() else { throw .notInBuild }
        guard allowRegister() else { throw .notReady }
        try await service.enable(requiresApproval: Failure.requiresApproval, failed: Failure.failed)
    }
}
