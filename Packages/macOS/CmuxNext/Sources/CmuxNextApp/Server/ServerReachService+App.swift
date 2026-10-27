import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import SystemConfiguration

extension ServerReachService {
    /// This Mac as a possible placed server: every name it answers to
    /// (gethostname, LocalHostName, computer name) and the brain's daemon
    /// socket, when one exists (a stat; nothing is read).
    static func thisMac() -> ServerReachPlan.LocalServer? {
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmux/brains/chief/daemon/cmux.sock").path
        guard FileManager.default.fileExists(atPath: socket) else { return nil }
        var names: [String] = []
        var buffer = [CChar](repeating: 0, count: 256)
        // SAFETY: gethostname writes at most buffer.count bytes into the array's storage, live for the call.
        if unsafe gethostname(&buffer, buffer.count) == 0 {
            names.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { names.append(local) }
        // SAFETY: the encoding pointer is nil, so SCDynamicStoreCopyComputerName writes no caller memory.
        if let computer = unsafe SCDynamicStoreCopyComputerName(nil, nil) as String? { names.append(computer) }
        let short = names.compactMap { $0.split(separator: ".").first.map(String.init) }.filter { !$0.isEmpty }
        return short.isEmpty ? nil : ServerReachPlan.LocalServer(hostNames: short, brainSocket: socket)
    }

    /// This Mac's link through the bundled CLI (`cmux link show`, `cmux link
    /// peer list`), running or not: nil when the CLI is missing or `show`
    /// fails (no link set up here).
    nonisolated static func readLinkPeers(binary: URL?) async -> ServerReachPlan.LinkPeers? {
        guard let binary else { return nil }
        func run(_ arguments: [String]) async -> Data? {
            guard let result = try? await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil,
                                                            timeout: .seconds(10), clock: ContinuousClock()),
                  result.status == 0 else { return nil }
            return result.stdout
        }
        guard let show = await run(["link", "show"]) else { return nil }
        return ServerReachPlan.linkPeers(show: show, peers: await run(["link", "peer", "list"]))
    }

    /// The registry transport for `session`: the reach plus whether it connects at launch.
    static func transport(_ session: ServerMachineSession) -> JSONValue {
        var fields = session.reach.transportFields.mapValues(JSONValue.string)
        fields["connect"] = .string(session.autoConnect ? "true" : "false")
        return .object(fields)
    }

    /// The App's service: reads as the signed-in user through the feed's
    /// API Worker call, dials with the bundled cmux-tui.
    static func app(services: AppServices) -> ServerReachService {
        let auth = services.cloudAuth  // the feed at the first call: the policy enforcer builds this service at launch
        let binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        // The bundle's own CLI, never one found on PATH.
        let bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        let cli = bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        return ServerReachService(
            machines: services.machines,
            mainWork: services.mainWork,
            appEvents: services.appEvents,
            call: { [weak services] path, body in
                guard let feed = services?.feed else { throw FeedServiceError.signedOut }
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
            return CloudPairingSource.app(feed: services.feed, auth: services.cloud.auth, work: services.work, mainWork: services.mainWork,
                                   chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
        })
    }
}
