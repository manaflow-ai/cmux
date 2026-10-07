import CmuxNextCloud
import CmuxNextRemote
import Foundation

extension AppServices {
    /// Add Server placed the user's Chief on a server: Home re-checks its
    /// Chief tab and the server's session joins the sidebar.
    func chiefPlaced() {
        home.refreshChiefTab()
        serverReach.refresh()
    }
}

extension ServerReachService {
    /// The App's service: reads as the signed-in user through the feed's
    /// API Worker call, dials with the bundled cmux-tui.
    static func app(machines: MachineRegistry, feed: FeedService, auth: CloudAuth, bundleID: String?) -> ServerReachService {
        ServerReachService(
            machines: machines,
            call: { [weak feed] path, body in
                guard let feed else { throw FeedServiceError.signedOut }
                return try await feed.call(path, body)
            },
            signedInUser: { [weak auth] in
                guard let auth, auth.isSignedIn else { return nil }
                return auth.user?.id ?? ""
            },
            paths: SSHPaths.standard(bundleID: bundleID),
            binary: try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment),
            local: { ServerReachService.thisMac() })
    }
}
