import CmuxMobileConnectHost
import CmuxMobileHost
import CmuxNextDaemon
import CmuxNextMobileLink
import Foundation

/// Builds the host's features from the app's services over the link's
/// daemon connection (D1b): C4 files over the workspace store's directories,
/// C13 git over the session host's git reads (same roots), C14 tunnels over
/// the workspaces' processes minus this Mac's own listeners, C14
/// simulators, C2 browser pages, C3 remote desktop and the C8 task runner
/// over acpmux.
enum MobileLinkFeatureFactory {
    static func features(_ services: MobileLinkServices, daemon: DaemonMobileDaemon, hostID: String,
                         names: @escaping MobileLinkServices.DeviceNames) -> MobileHostFeatures {
        let files = MobileFiles(configuration: MobileFilesConfiguration(homeDirectory: services.homeDirectory),
                                roots: DaemonFileRoots(daemon: daemon))
        var handlers = files.registering()
        handlers = MobileGit(sharing: files, reader: DaemonGitReader(connection: daemon.connection)).registering(into: handlers)
        let scanner = LibprocListeningPortScanner()
        let detected = DetectedTunnelPorts(processes: DaemonWorkspaceProcesses(daemon: daemon), scanner: scanner,
                                           allowed: StaticAllowedPorts(services.allowedPorts))
        let connection = daemon.connection
        let ports = FilteredTunnelPorts(base: detected) {
            var pids = [ProcessInfo.processInfo.processIdentifier]
            if let pid = await connection.endpoint?.pid { pids.append(pid) }
            return Set(scanner.listeningPorts(of: pids).values.flatMap { $0 })
        }
        handlers = MobileTunnels(ports: ports).registering(into: handlers)
        if let simulators = services.simulators {
            handlers = MobileSimulators(host: simulators).registering(into: handlers)
        }
        var channels = handlers.channels
        if let pages = services.browserPages { channels[.browser] = BrowserChannelHandler(pages: pages) }
        if let remoteDesktop = services.remoteDesktop { channels[.rd] = remoteDesktop(names) }
        handlers = MobileChannelHandlers(channels: channels, reads: handlers.reads)
        var runner: (any MobileTaskRunner)?
        if let socketPath = services.acpmuxSocketPath, let agentHost = services.agentHost, let agentHomes = services.agentHomes {
            runner = AcpmuxMobileTaskRunner(
                hostID: hostID,
                workspaces: DaemonTaskWorkspaces(daemon: daemon, agentHost: agentHost, agentHostName: services.agentHostName,
                                                 agentHomes: agentHomes),
                connect: {
                    guard let path = await socketPath() else { throw AcpmuxRPCError("acpmux is not running on this Mac") }
                    return try await AcpmuxSocketRPC.connect(socketPath: path)
                })
        }
        return MobileHostFeatures(handlers: handlers, taskRunner: runner, caps: [MobileGit.cap],
                                  allowsTaskDispatch: services.allowsTaskDispatch, allowsTerminalSpawn: services.allowsTerminalSpawn)
    }
}
