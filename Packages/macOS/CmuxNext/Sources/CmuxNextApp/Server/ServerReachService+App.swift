import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextHostedChief
import CmuxNextMobileHost
import CmuxNextPages
import CmuxNextRemote
import CmuxNextServer
import Foundation

extension ServerReachService {
    /// The App's service: reads as the signed-in user through the feed's
    /// API Worker call, dials with the bundled cmux-tui.
    static func app(services: AppServices) -> ServerReachService {
        let feed = services.feed, auth = services.cloud.auth
        let binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        // The bundle's own CLI (or the source-built one `CMUX_NEXT_TUI_BIN` names), never one found on PATH.
        let bundled: URL? = services.bundledCLI.candidate
        let cli = bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        return ServerReachService(
            machines: services.machines,
            mainWork: services.mainWork,
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
                // The app's own daemon state root (its build's), which
                // only the daemon gets as CMUX_TUI_STATE_DIR.
                var environment = ProcessInfo.processInfo.environment
                if let stateDirectory = services.environment.daemonStateDirectory {
                    environment["CMUX_TUI_STATE_DIR"] = stateDirectory.path
                }
                return ServerReachPlan.defaultLinkSetupFile(environment: environment, home: NSHomeDirectory())
            })
    }
}

extension ServerMenuBarController {
    /// The App's menu bar item: this Mac's server status plus cloud pairing as the signed-in user.
    static func app(services: AppServices) -> ServerMenuBarController {
        ServerMenuBarController(makeSource: { [weak services] in
            guard let services else { return nil }
            return CloudPairingSource.app(feed: services.feed, auth: services.cloud.auth, cli: services.bundledCLI,
                                   chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
        }, makeCards: { [weak services] in services.flatMap { WebCardPanel.serverCards(services: $0) } })
    }
}

extension WebCardPanel {
    /// The App's server card panel, kept warm: Pair Another Machine (the invite minted and watched as the
    /// signed-in user; its arrived machine previewed and approved by Add Server's own cloud source).
    @MainActor
    static func serverCards(services: AppServices) -> WebCardPanel? {
        let feed = services.feed
        let call: CloudPairingSource.Call = { [weak feed] path, body in
            guard let feed else { throw FeedServiceError.signedOut }
            return try await feed.call(path, body)
        }
        let pairing = CloudPairingSource(
            inner: NoLocalServerSource(), call: call,
            account: { [weak auth = services.cloud.auth] in
                guard let auth, auth.isSignedIn else { return nil }
                return auth.user?.displayName ?? auth.user?.primaryEmail ?? ""
            },
            chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
        let approver = ServerModel(source: pairing)
        approver.start()
        let qrCode = PairingQRCode()
        let invite = PairInviteCardProvider(
            service: .cloud(
                team: { try await pairing.workerTeam()?.id },
                call: { try CloudPairingSource.okValue(try await pairing.call($0, $1)) },
                texts: .init(
                    failed: { RefusalStrings.format("refusal.server.inviteFailed", "Could not make a pairing code: %@", $0) },
                    unreachable: RefusalStrings.text("refusal.server.pairUnreachable", "Could not reach cmux. Check the connection and try again."),
                    notMade: RefusalStrings.text("refusal.server.inviteNotMade", "cmux could not make a pairing code. Try again.")),
                apiBaseURL: feed.apiBaseURL),
            approver: approver,
            // A single-use code: marked concealed and transient (nspasteboard.org) so clipboard managers do not keep it.
            copy: { SystemPasswordPasteboard().write($0, markers: [ConcealedPasteboard.concealedType, ConcealedPasteboard.transientType]) },
            qr: { qrCode.pngDataURL(for: $0) })
        guard let panel = WebCardPanel(descriptor: .serverCards, cards: [invite], overlayProcess: services.overlayProcess) else { return nil }
        panel.isPersonEvent = { [person = PersonInputCheck(sources: services.personInput.sources)] in person.isPerson($0) }
        return panel
    }
}
