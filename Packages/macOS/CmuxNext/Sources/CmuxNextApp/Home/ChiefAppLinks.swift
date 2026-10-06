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

    /// Points both links at this app (last writer wins), each atomically.
    static func publish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        _ = (home, controlSocket, daemonSocket)
    }

    /// Removes the links that still point at this app's sockets (another
    /// build that took them over keeps them).
    static func unpublish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        _ = (home, controlSocket, daemonSocket)
    }

    /// A temporary link renamed over the old one, so readers never see none.
    private static func point(_ link: URL, at target: String) {
        let temporary = link.path + ".\(getpid()).tmp"
        unlink(temporary)
        guard symlink(target, temporary) == 0 else { return }
        if rename(temporary, link.path) != 0 { unlink(temporary) }
    }
}
