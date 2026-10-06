import CmuxNextActions
import CmuxNextAgentPane
import Foundation
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
/// The mux home is the Chief home (`ChiefHome`): one per account, shared by
/// every build, so the memory is one history; isolated launches (agent
/// preflights, tests) get their own. The host lock keeps one host per home:
/// a second build's launch exits at once and its Home shows the running
/// host's conversation, which lives in the Chief home's own owner.
nonisolated struct HomeBrainHost: Sendable {
    let executable: URL
    let muxHome: URL
    let daemonSocket: String
    /// This app's control socket, so the mux's `cmux` calls reach this app (tagged builds included).
    let controlSocket: String
    let acpmux: AcpmuxEnvironment?

    /// The OptChat Chief's file name in the app's Contents/Resources/bin.
    static let bundledChiefName = "optchat-chief"

    /// DEV (a Debug compile) and NIGHTLY (`com.cmuxterm.app.nightly[.<tag>]`)
    /// start the bundled Chief; Release and RC do not (NIGHTLY compiles as
    /// Release, so the bundle id decides, as for DevTools).
    static func bundledChiefAllowed(bundleID: String?, isDebugBuild: Bool) -> Bool {
        DevTools.isAvailable(bundleID: bundleID, isDebugBuild: isDebugBuild)
    }

    static func resolve(daemonSocket: String, controlSocket: String, home: ChiefHome,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        bundledBinDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                        bundledChiefAllowed: Bool = HomeBrainHost.bundledChiefAllowed(bundleID: Bundle.main.bundleIdentifier,
                                                                                      isDebugBuild: DevTools.isDebugBuild)) -> HomeBrainHost? {
        let override = environment["CMUX_NEXT_MUX_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        let bundled = bundledChiefAllowed ? bundledBinDirectory?.appendingPathComponent(bundledChiefName).path : nil
        guard let path = [override, bundled].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // The Chief's turns and subagents run on the Chief home's acpmux, never
        // a tag's: a host started later by another build finds the sessions
        // its state names.
        var acpmuxEnvironment = environment
        acpmuxEnvironment["ACPMUX_HOME"] = home.acpmuxHome.path
        acpmuxEnvironment.removeValue(forKey: "ACPMUX_SOCKET")
        return HomeBrainHost(executable: URL(fileURLWithPath: path), muxHome: home.muxHome, daemonSocket: daemonSocket, controlSocket: controlSocket,
                             acpmux: AcpmuxEnvironment.resolve(tag: nil, bundledBinDirectory: bundledBinDirectory, environment: acpmuxEnvironment))
    }

    var arguments: [String] {
        ["-c", #"set -m; "$@" >>"$MUX_HOST_LOG" 2>&1 </dev/null &"#, "mux-host-launch",
         executable.path, "host", "--daemon-socket", daemonSocket, "--mux-home", muxHome.path]
    }

    var childEnvironment: [String: String] {
        var variables: [String: String] = [
            "PATH": Self.searchPath(home: FileManager.default.homeDirectoryForCurrentUser),
            // Constant links to the app that last opened Home (ChiefAppLinks):
            // the host outlives the app that started it.
            "CMUX_SOCKET_PATH": ChiefAppLinks.controlLink(ChiefHome(root: muxHome, isolated: false)).path,
            "CMUX_APP_DAEMON_SOCKET": ChiefAppLinks.daemonLink(ChiefHome(root: muxHome, isolated: false)).path,
            "MUX_AGENT_TOKEN_FILE": tokenFile.path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "MUX_HOST_LOG": muxHome.appendingPathComponent("host.log").path,
            // The host's chief create request must equal the app's (the owner
            // refuses a different request under the same key).
            "MUX_USER_NAME": HomeChiefName.localUserName,
            // ...and its title (HomeChiefName.createRequest, localized).
            "MUX_CHIEF_TITLE": HomeStrings.chiefName,
        ]
        if let acpmux {
            variables.merge(acpmux.childEnvironment) { $1 }
            variables["ACPMUX_BIN"] = acpmux.executable.path
        }
        for key in ["USER", "TMPDIR", "MUX_HARNESS", "CMUX_MCP_COMMAND"] {
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

    @concurrent func launch(agentToken: String) async {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
        do {
            try FileManager.default.createDirectory(at: muxHome, withIntermediateDirectories: true)
            // Created 0600 from the start, so the token is never readable by others.
            try? FileManager.default.removeItem(at: tokenFile)
            guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data(agentToken.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                logger.error("mux agent token file could not be written")
                return
            }
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = arguments
            shell.environment = childEnvironment
            shell.standardInput = FileHandle.nullDevice
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            logger.info("mux host started for \(muxHome.path, privacy: .public)")
        } catch {
            logger.error("mux host failed to start: \(String(describing: error), privacy: .public)")
        }
    }
}
