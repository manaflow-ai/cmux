import CmuxNextDaemon
import CmuxNextRemote
import Foundation

extension ServerReachService {
    /// The App's service: reads as the signed-in user through the feed's
    /// API Worker call, dials with the bundled cmux-tui.
    static func app(services: AppServices) -> ServerReachService {
        let feed = services.feed, auth = services.cloud.auth
        let binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        // The bundle's own CLI, never one found on PATH.
        let bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        let cli = bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        return ServerReachService(
            machines: services.machines,
            call: { [weak feed] path, body in
                guard let feed else { throw FeedServiceError.signedOut }
                return try await feed.call(path, body)
            },
            signedInUser: { [weak auth] in
                guard let auth, auth.isSignedIn else { return nil }
                return auth.user?.id ?? ""
            },
            paths: SSHPaths.standard(bundleID: services.environment.launch.bundleID),
            binary: binary,
            local: { ServerReachService.thisMac() },
            linkPeers: { await ServerReachService.readLinkPeers(binary: cli) },
            cli: cli,
            linkSetupFile: cli.map { _ in
                ServerReachPlan.defaultLinkSetupFile(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
            })
    }
}

extension ServerMenuBarController {
    /// The App's menu bar item: this Mac's server status plus cloud pairing as the signed-in user.
    static func app(services: AppServices) -> ServerMenuBarController {
        ServerMenuBarController(makeSource: { [unowned services] in
            CloudPairingSource.app(feed: services.feed, auth: services.cloud.auth,
                                   chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
        })
    }
}
