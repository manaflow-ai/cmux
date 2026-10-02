import CmuxNextAgentPane
import Foundation
import os

/// Starts the local mux brain host (plans/cmux-next/home.md section 4) when
/// Home first opens: a detached process (its own process group, adopted by
/// launchd) that is a client of the daemon's conversation owner and of acpmux,
/// and listens on nothing. It outlives the app; its own pid lock keeps one
/// instance per mux home, so starting it again is harmless.
///
/// Phase A: the host is the TypeScript `mux` executable named by
/// `CMUX_NEXT_MUX_HOST` (a `bun build --compile` binary of `mux/`); without it
/// Home works and the mux simply does not answer. Tagged builds use
/// `~/.cmux/mux/tags/<tag>` so a test never touches the real mux memory.
nonisolated struct HomeBrainHost: Sendable {
    let executable: URL
    let muxHome: URL
    let daemonSocket: String
    /// This app's control socket, so the mux's `cmux` calls reach this app (tagged builds included).
    let controlSocket: String
    let acpmux: AcpmuxEnvironment?

    static func resolve(daemonSocket: String, controlSocket: String, tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> HomeBrainHost? {
        guard let path = environment["CMUX_NEXT_MUX_HOST"], !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        let base = userHome.appendingPathComponent(".cmux/mux", isDirectory: true)
        let home: URL
        if let custom = environment["CMUX_NEXT_MUX_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: custom, isDirectory: true)
        } else if let tag, !tag.isEmpty {
            home = base.appendingPathComponent("tags/\(tag)", isDirectory: true)
        } else {
            home = base
        }
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return HomeBrainHost(executable: URL(fileURLWithPath: path), muxHome: home, daemonSocket: daemonSocket, controlSocket: controlSocket,
                             acpmux: AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: bin, environment: environment))
    }

    var arguments: [String] {
        ["-c", #"set -m; "$@" >>"$MUX_HOST_LOG" 2>&1 </dev/null &"#, "mux-host-launch",
         executable.path, "host", "--daemon-socket", daemonSocket, "--mux-home", muxHome.path]
    }

    var childEnvironment: [String: String] {
        var variables: [String: String] = [
            "PATH": Self.searchPath(home: FileManager.default.homeDirectoryForCurrentUser),
            "CMUX_SOCKET_PATH": controlSocket,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "MUX_HOST_LOG": muxHome.appendingPathComponent("host.log").path,
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
    @concurrent func launch() async {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
        do {
            try FileManager.default.createDirectory(at: muxHome, withIntermediateDirectories: true)
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
