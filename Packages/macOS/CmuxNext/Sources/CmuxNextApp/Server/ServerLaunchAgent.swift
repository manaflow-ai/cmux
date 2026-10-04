import Foundation
import ServiceManagement

/// Keeps the Mac's server running when the app quits (plans/cmux-next/server.md 4.3):
/// a launchd agent registered with `SMAppService.agent` from the plist the app
/// bundle carries in `Contents/Library/LaunchAgents`. The agent runs the bundled
/// `cmux host run`. Builds without the server software do not carry the plist.
/// `ServerStopServing` unregisters it.
enum ServerLaunchAgent {
    static let plistName = "com.cmux.server.plist"

    enum Failure: Error, Equatable {
        /// The bundle has no agent plist (the server software is not in this build).
        case notInBuild
        /// The user must allow the agent in System Settings > Login Items.
        case requiresApproval
        case failed(String)
    }

    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(plistName)").path)
    }

    static var isRegistered: Bool {
        isBundled && SMAppService.agent(plistName: plistName).status == .enabled
    }

    /// Registers the agent. Idempotent: an enabled agent stays enabled.
    static func register() throws(Failure) {
        guard isBundled else { throw .notInBuild }
        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw .requiresApproval
        default:
            do {
                try service.register()
            } catch {
                throw .failed(String(describing: error))
            }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw .requiresApproval
            }
        }
    }
}
