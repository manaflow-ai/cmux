public import CmuxNextActions
public import CmuxNextCompat
import CmuxNextAgentPane
public import Foundation
import os

/// Starts the local mux brain host (plans/cmux-next/home.md section 4) when
/// Home first opens: a detached process (its own process group, adopted by
/// launchd) that is a client of the daemon's conversation owner and of acpmux,
/// and listens on nothing. It outlives the app; its own pid lock keeps one
/// instance per mux home, so starting it again is harmless.
///
/// The host is the executable named by `CMUX_NEXT_MUX_HOST` (the TypeScript
/// `mux`, or a local optchat-chief build), else the OptChat Chief that DEV
/// and NIGHTLY builds bundle as Contents/Resources/bin/optchat-chief
/// (scripts/cmux-next/bundle-optchat-chief.sh; Native/OptChat/optchat-chief,
/// chief-done.md check 7: every Chief turn follows OptChat). The bundled
/// Chief starts only on DEV and NIGHTLY (`bundledChiefAllowed`, the
/// DevTools channel rule); Release and RC never bundle or start it: Home
/// works and the Chief does not answer. Both keep the
/// `host --daemon-socket --mux-home` contract and one lock per mux home.
/// The mux home is this build's Chief home (`ChiefHome`, one Chief per
/// build); isolated launches (agent preflights, tests) get their own. The
/// host lock keeps one host per home: a second launch (or one `cmux chief`
/// started) exits at once. When the host dies while the app runs, Home
/// starts it again (`ChiefBrainWatch`).
public nonisolated struct HomeBrainHost: Sendable {
    let executable: URL
    let muxHome: URL
    let daemonSocket: String
    /// This app's control socket, so the mux's `cmux` calls reach this app (tagged builds included).
    let controlSocket: String
    let acpmux: AcpmuxEnvironment?
    /// The Chief runs on the app's own acpmux (``ChiefHome/usesAppAcpmux``): the host only
    /// waits for that daemon (`OPTCHAT_ACPMUX_SUPERVISED=1`), never starts, stops or hands it off.
    var usesAppAcpmux = false
    /// Starts the app's own acpmux when none runs (the local pane host's prewarm), before a host
    /// that only waits for it launches. Nil: nothing to start.
    public var ensureAppAcpmux: (@Sendable () async -> Void)?

    /// The OptChat Chief's file name in the app's Contents/Resources/bin.
    static let bundledChiefName = "optchat-chief"

    /// DEV (a Debug compile) and NIGHTLY (`com.cmuxterm.app.nightly[.<tag>]`)
    /// start the bundled Chief; Release and RC do not (NIGHTLY compiles as
    /// Release, so the bundle id decides, as for DevTools).
    public static func bundledChiefAllowed(bundleID: String?, isDebugBuild: Bool) -> Bool {
        DevTools.isAvailable(bundleID: bundleID, isDebugBuild: isDebugBuild)
    }

    /// Whether this app can start a host at all (`resolve` finds an executable).
    public static func canStart(environment: [String: String] = ProcessInfo.processInfo.environment,
                                bundledBinDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                                bundledChiefAllowed: Bool = HomeBrainHost.bundledChiefAllowed(bundleID: Bundle.main.bundleIdentifier,
                                                                                              isDebugBuild: DevTools.isDebugBuild)) -> Bool {
        // The build-session kill switch: no Chief host, so no brain starts (cx-9ettq).
        if AcpmuxEnvironment.agentLaunchDisabled(environment) { return false }
        let override = environment["CMUX_NEXT_MUX_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        let bundled = bundledChiefAllowed ? bundledBinDirectory?.appendingPathComponent(bundledChiefName).path : nil
        return [override, bundled].compactMap { $0 }.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Home's notice on this Mac's Chief while the build-session kill switch
    /// is on (cx-tgf4h): no host starts, so the Chief cannot answer; nil else.
    public static func agentsDisabledNotice(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        AcpmuxEnvironment.agentLaunchDisabled(environment) ? HomeStrings.chiefAgentsDisabled : nil
    }

    /// - Parameter appBuild: the build whose acpmux the app's panes use (`AppEnvironment.build`);
    ///   a Chief on the app's acpmux (``ChiefHome/usesAppAcpmux``) resolves the same daemon.
    public static func resolve(daemonSocket: String, controlSocket: String, home: ChiefHome, appBuild: BuildIdentity? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        bundledBinDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                        bundledChiefAllowed: Bool = HomeBrainHost.bundledChiefAllowed(bundleID: Bundle.main.bundleIdentifier,
                                                                                      isDebugBuild: DevTools.isDebugBuild)) -> HomeBrainHost? {
        if AcpmuxEnvironment.agentLaunchDisabled(environment) { return nil }
        let override = environment["CMUX_NEXT_MUX_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        let bundled = bundledChiefAllowed ? bundledBinDirectory?.appendingPathComponent(bundledChiefName).path : nil
        guard let path = [override, bundled].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // NIGHTLY's Chief runs on the app's own acpmux (`~/.acpmux`, as the app's panes resolve
        // it); any other Chief on its Chief home's, never a tag's: a host started later by
        // another build finds the sessions its state names.
        var acpmuxEnvironment = environment
        let usesAppAcpmux = home.usesAppAcpmux
        if !usesAppAcpmux {
            acpmuxEnvironment["ACPMUX_HOME"] = home.acpmuxHome.path
            acpmuxEnvironment.removeValue(forKey: "ACPMUX_SOCKET")
        }
        var host = HomeBrainHost(executable: URL(fileURLWithPath: path), muxHome: home.muxHome, daemonSocket: daemonSocket, controlSocket: controlSocket,
                                 acpmux: AcpmuxEnvironment.resolve(build: usesAppAcpmux ? appBuild : nil, bundledBinDirectory: bundledBinDirectory,
                                                                   environment: acpmuxEnvironment))
        host.usesAppAcpmux = usesAppAcpmux
        return host
    }

    /// This build's Chief home's mux home (`ChiefHome`); the engine bar,
    /// sidebar and files read it.
    public static func muxHome(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        ChiefHome.resolve(tag: tag, environment: environment, userHome: userHome).muxHome
    }

    /// The shell prints the host's pid, so Home watches that process's exit.
    var arguments: [String] {
        ["-c", #"set -m; "$@" >>"$MUX_HOST_LOG" 2>&1 </dev/null & echo "$!""#, "mux-host-launch",
         executable.path, "host", "--daemon-socket", daemonSocket, "--mux-home", muxHome.path]
    }

    var childEnvironment: [String: String] {
        var variables: [String: String] = [
            "PATH": Self.searchPath(home: FileManager.default.homeDirectoryForCurrentUser),
            // Constant links to the app that last opened Home (ChiefAppLinks):
            // the host outlives the app that started it.
            "MUX_AGENT_TOKEN_FILE": tokenFile.path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "MUX_HOST_LOG": muxHome.appendingPathComponent("host.log").path,
            // `cmux chief` in the brain's turns and subagents opens this Chief
            // (one Chief per build), never the shared home by default.
            "CMUX_CHIEF_HOME": muxHome.path,
            // The host's chief create request must equal the app's (the owner
            // refuses a different request under the same key).
            "MUX_USER_NAME": HomeChiefName.localUserName,
            // ...and its title (HomeChiefName.createRequest, localized).
            "MUX_CHIEF_TITLE": HomeStrings.chiefName,
        ]
        variables.merge(ChiefAppLinks.hostEnvironment(ChiefHome(root: muxHome, isolated: false))) { $1 }
        if let acpmux {
            variables.merge(acpmux.childEnvironment) { $1 }
            variables["ACPMUX_BIN"] = acpmux.executable.path
        }
        // The app owns its acpmux: the host waits for it and never starts or stops it
        // (optchat-chief acpmux_daemon::Mode::Supervised). Never OPTCHAT_ACPMUX_SHARED: its last
        // Chief to leave ends every session of the daemon, the person's too.
        if usesAppAcpmux { variables["OPTCHAT_ACPMUX_SUPERVISED"] = "1" }
        // No CMUX_MCP_COMMAND: acpmux gives every agent chat, the Chief's
        // turns included, its own `cmux mcp serve` (one server per turn).
        for key in ["USER", "TMPDIR", "MUX_HARNESS"] {
            if let value = ProcessInfo.processInfo.environment[key] { variables[key] = value }
        }
        return variables
    }

    /// The app's bundled CLI first (so `cmux` in the mux's shell is this build's), then the
    /// user's tool directories, where acpmux finds agent harnesses such as `sr` (claude-sr),
    /// then the system. Phase A stand-in for the daemon login environment (spec D26, open).
    static func searchPath(home: URL) -> String {
        let user = ["bin", ".local/bin", ".bun/bin", ".cargo/bin"].map { home.appendingPathComponent($0).path }
        return ([Bundle.main.resourceURL?.appendingPathComponent("bin").path].compactMap { $0 } + user
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }

    /// Spawns the host through a throwaway shell with job control, so it gets
    /// its own process group and is adopted by launchd when the shell exits.
    /// The file that hands the mux's conversation token to the host (0600).
    var tokenFile: URL { muxHome.appendingPathComponent("agent-token") }

    /// What `start` did.
    public enum StartOutcome: Equatable, Sendable {
        /// A live host holds the home's lock and its token: no new token.
        case reusedRunningHost(pid: pid_t?)
        /// A token was minted and a host launched (its pid when known).
        case launched(pid: pid_t?)

        /// The process to watch: when it exits, Home starts the host again.
        public var pid: pid_t? {
            switch self {
            case .reusedRunningHost(let pid), .launched(let pid): pid
            }
        }
    }

    /// Starts the host for a Home that opened. `mintToken` replaces the
    /// owner's agent_mux credential and revokes the binding of the host that
    /// runs, so it is called only when the host must start.
    @concurrent public func start(mintToken: @Sendable () async throws -> String) async throws -> StartOutcome {
        // cmux NEXT's one-time adoption of its old homes ends before its brain starts (cx-is1kf.9).
        await AcpmuxEnvironment.adoptBuildHomes()
        // A Chief-home acpmux that runs from a replaced bundle (an update replaced the
        // app it ran from, so the peer check refuses it and Chief chats say acpmux did
        // not start), or without this Chief home (an older build, or one an app started
        // before ACPMUX_CHIEF_MUX_HOME), is handed off (AcpmuxChiefHandoff).
        // Only the Chief host starts that daemon (a tab never does, cx-ebm.54): the
        // host that ran on it ends, and the one launched below starts it with this
        // Chief home's env.
        // An update never cuts a Chief turn: a host that takes it is asked to hand off when idle
        // (SIGUSR1) and keeps this daemon until its turn ends; its exit restarts this start
        // (ChiefBrainWatch), which then hands the daemon off. Only an older host is stopped here.
        let chiefHome = ChiefHome(root: muxHome, isolated: false)
        // The app's own acpmux is the app's to start and hand off (its version handoff), never
        // the Chief's: it runs the person's chats too. A daemon started without this Chief home
        // (`ACPMUX_CHIEF_MUX_HOME`, e.g. by the CLI) is kept: it gets it at its next start.
        // A host still on the Chief's own daemon (the previous build's after an update) moves
        // over, and that daemon ends (ChiefAppAcpmuxMove).
        if usesAppAcpmux, let acpmux {
            await ensureAppAcpmux?()
            let move = ChiefAppAcpmuxMove(home: chiefHome, app: acpmux)
            guard await move.run() else {
                // It hands off when its turn ends; its exit brings the next start (ChiefBrainWatch).
                return .reusedRunningHost(pid: ChiefHostStop.runningHostPID(home: chiefHome))
            }
        } else {
            // The kill switch (`CMUX_CHIEF_OWN_ACPMUX=1`) is on: a host this app launched on the
            // app's acpmux moves back to the Chief's own daemon.
            guard await ChiefAppAcpmuxMove.leaveAppAcpmux(home: chiefHome) else {
                return .reusedRunningHost(pid: ChiefHostStop.runningHostPID(home: chiefHome))
            }
            if let acpmux, await AcpmuxChiefHandoff(environment: acpmux, chiefMuxHome: muxHome.path)
                .handOffIfStale(waitFor: { ChiefHostStop.askToHandOffWhenIdle(home: chiefHome) != nil }),
               let pid = await ChiefHostStop.stop(home: chiefHome) {
                _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
            }
        }
        // A live host reads the token file at each connect: keep its binding.
        if runningHostHasToken {
            return .reusedRunningHost(pid: ChiefHostStop.runningHostPID(home: ChiefHome(root: muxHome, isolated: false)))
        }
        let token = try await mintToken()
        let pid = await launch(agentToken: token)
        // A pid the launch could not read: the host's lock names it, so the next start does
        // not take this new host for an old one and restart it.
        if usesAppAcpmux, let acpmux, let marked = pid ?? ChiefHostStop.runningHostPID(home: chiefHome) {
            ChiefAppAcpmuxMove(home: chiefHome, app: acpmux).mark(pid: marked)
        }
        return .launched(pid: pid)
    }

    /// Whether a host holds this home's lock (`state/host.lock`) and the
    /// token file it reconnects with is there.
    var runningHostHasToken: Bool {
        // concurrency-allow: a small local file read, off the main actor in `start`
        let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !token.isEmpty && ChiefMigration.lockHeld(at: muxHome.appendingPathComponent("state/host.lock"))
    }

    @concurrent func launch(agentToken: String) async -> pid_t? {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
        do {
            try FileManager.default.createDirectory(at: muxHome, withIntermediateDirectories: true)
            // Created 0600 from the start, so the token is never readable by others.
            try? FileManager.default.removeItem(at: tokenFile)
            guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data(agentToken.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                logger.error("mux agent token file could not be written")
                return nil
            }
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = arguments
            shell.environment = childEnvironment
            // LAUNCH-NO-TCC-PROMPTS: the host and what it starts without a
            // folder of its own (its acpmux daemon) run in the Chief home,
            // never the app's folder (`/`) or the home folder, where an
            // agent reads Downloads, Documents and Desktop at once.
            shell.currentDirectoryURL = muxHome
            shell.standardInput = FileHandle.nullDevice
            let output = Pipe()
            shell.standardOutput = output
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            // The shell exits right after the background start; its one line is the pid.
            // concurrency-allow: one pid line from a shell that exits at once, off the main actor in @concurrent `launch`
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let pid = pid_t(printed.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 1 ? $0 : nil }
            logger.info("mux host started for \(muxHome.path, privacy: .public) pid \(pid.map(String.init) ?? "?", privacy: .public)")
            return pid
        } catch {
            logger.error("mux host failed to start: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
