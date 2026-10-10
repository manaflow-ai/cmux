import Darwin
import Foundation

/// Which app the Chief works in (agreed with the workspace-routing lane,
/// feat-cmux-next-chief-ws-routing): two symlinks in the Chief home point at
/// the control socket and the tagged daemon socket of the app that last opened
/// or activated Home. The brain host and every turn and subagent session get
/// the links' constant paths (`CMUX_SOCKET_PATH`, `CMUX_APP_DAEMON_SOCKET`),
/// so their environment never changes (the prompt cache stays whole), and
/// connect(2) follows the link to the running app. The host outlives the app
/// that started it; with no app running a link dangles and a `cmux` call fails
/// at once instead of reaching a dead build.
nonisolated enum ChiefAppLinks {
    static func controlLink(_ home: ChiefHome) -> URL { home.root.appendingPathComponent("state/app.sock") }
    static func daemonLink(_ home: ChiefHome) -> URL { home.root.appendingPathComponent("state/app-daemon.sock") }

    /// The links the brain host gets (`HomeBrainHost.childEnvironment`).
    static func hostEnvironment(_ home: ChiefHome) -> [String: String] {
        ["CMUX_SOCKET_PATH": controlLink(home).path, "CMUX_APP_DAEMON_SOCKET": daemonLink(home).path]
    }

    /// The env of the Chief home's acpmux daemon, whoever starts it (the host
    /// pins the same values, optchat-chief `cmux_env::pin`): the Chief home for
    /// the built-in Chief presets' codex homes (`ACPMUX_CHIEF_MUX_HOME`, acpmux
    /// `config/chief_builtins.rs`), the host's links, and the app's daemon (the
    /// daemon link) as the socket every `cmux` call of a subagent reaches.
    static func acpmuxEnvironment(_ home: ChiefHome) -> [String: String] {
        var variables = hostEnvironment(home)
        variables["ACPMUX_CHIEF_MUX_HOME"] = home.muxHome.path
        variables["CMUX_TUI_SOCKET"] = daemonLink(home).path
        variables["CMUX_MUX_SOCKET"] = daemonLink(home).path
        return variables
    }

    /// Points both links at this app (last writer wins), each atomically.
    static func publish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        let state = home.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        point(controlLink(home), at: controlSocket)
        if let daemonSocket { point(daemonLink(home), at: daemonSocket) }
    }

    /// Removes the links that still point at this app's sockets (another
    /// build that took them over keeps them).
    static func unpublish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        for (link, target) in [(controlLink(home), controlSocket), (daemonLink(home), daemonSocket)] {
            guard let target, (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target else { continue }
            unlink(link.path)
        }
    }

    /// A temporary link renamed over the old one, so readers never see none.
    private static func point(_ link: URL, at target: String) {
        let temporary = link.path + ".\(getpid()).tmp"
        unlink(temporary)
        guard symlink(target, temporary) == 0 else { return }
        if rename(temporary, link.path) != 0 { unlink(temporary) }
    }
}
