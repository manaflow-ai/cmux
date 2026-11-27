import CmuxNextCompat
public import Foundation
public import ServiceManagement

/// Keeps the Mac's server running when the app quits (plans/cmux-next/server.md 4.3):
/// a launchd agent registered with `SMAppService.agent` from the plist the app
/// bundle carries in `Contents/Library/LaunchAgents` (written by
/// scripts/cmux-next/bundle-server-helper.sh, label `<bundle id>.server`). The
/// agent runs the bundled `cmux host run`. Builds without the bundled CLI do
/// not carry the plist. Registration also needs the Debug Settings switch
/// `server.agent.allowRegister` (off by default) until the bundled CLI ships
/// `cmux host run`. `ServerStopServing` unregisters it, switch or not.
/// This is the only place that registers the agent.
public struct ServerLaunchAgent {
    public static let plistName = "com.cmux.server.plist"

    public enum Failure: Error, Equatable {
        /// The bundle has no agent plist (the server software is not in this build).
        case notInBuild
        /// A dev build: the agent's `cmux host run` keeps one state for every build
        /// (`~/Library/Application Support/cmux/server`) and calls the cloud with no build space, so a dev
        /// build never registers it (AGENTS.md "Dev builds are separate").
        case devBuild
        /// The opt-in switch is off: the server software is not ready yet.
        case notReady
        /// The user must allow the agent in System Settings > Login Items.
        case requiresApproval
        case failed(String)
    }

    /// The `SMAppService` calls, as a seam.
    public struct Service {
        var status: @MainActor () -> SMAppService.Status
        var register: @MainActor () throws -> Void
        var openLoginItems: @MainActor () -> Void

        public init(status: @escaping @MainActor () -> SMAppService.Status, register: @escaping @MainActor () throws -> Void,
                    openLoginItems: @escaping @MainActor () -> Void) {
            self.status = status
            self.register = register
            self.openLoginItems = openLoginItems
        }
    }

    var isBundled: @MainActor () -> Bool
    /// The app is a dev build (``BuildIdentity/needsBuildSpace``).
    var isDevBuild: @MainActor () -> Bool = { false }
    var allowRegister: @MainActor () -> Bool
    var service: Service

    public init(isBundled: @escaping @MainActor () -> Bool, isDevBuild: @escaping @MainActor () -> Bool = { false },
                allowRegister: @escaping @MainActor () -> Bool, service: Service) {
        self.isBundled = isBundled
        self.isDevBuild = isDevBuild
        self.allowRegister = allowRegister
        self.service = service
    }

    public static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(plistName)").path)
    }

    public static func app() -> ServerLaunchAgent {
        ServerLaunchAgent(
            isBundled: { Self.isBundled },
            isDevBuild: { BuildIdentity(bundle: .main).needsBuildSpace },
            allowRegister: { ServerTunables.agentAllowRegister.value },
            service: Service(status: { SMAppService.agent(plistName: plistName).status },
                             register: { try SMAppService.agent(plistName: plistName).register() },
                             openLoginItems: { SMAppService.openSystemSettingsLoginItems() }))
    }

    /// Registers the agent. Idempotent: an enabled agent stays enabled.
    @MainActor
    public func register() throws(Failure) {
        guard isBundled() else { throw .notInBuild }
        guard !isDevBuild() else { throw .devBuild }
        guard allowRegister() else { throw .notReady }
        switch service.status() {
        case .enabled:
            return
        case .requiresApproval:
            service.openLoginItems()
            throw .requiresApproval
        default:
            do {
                try service.register()
            } catch {
                throw .failed(String(describing: error))
            }
            if service.status() == .requiresApproval {
                service.openLoginItems()
                throw .requiresApproval
            }
        }
    }
}
