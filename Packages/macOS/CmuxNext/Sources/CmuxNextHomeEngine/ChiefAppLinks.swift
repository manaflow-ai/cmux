import Darwin
import Foundation
import CmuxNextCompat

/// Which app the Chief works in (agreed with the workspace-routing lane,
/// feat-cmux-next-chief-ws-routing): two symlinks in the Chief home point at
/// the control socket and the tagged daemon socket of the app that last opened
/// or activated Home. The brain host and every turn and subagent session get
/// the links' constant paths (`CMUX_SOCKET_PATH`, `CMUX_APP_DAEMON_SOCKET`),
/// so their environment never changes (the prompt cache stays whole), and
/// connect(2) follows the link to the running app. The host outlives the app
/// that started it; with no app running a link dangles and a `cmux` call fails
/// at once instead of reaching a dead build.
public nonisolated enum ChiefAppLinks {
    static func controlLink(_ home: ChiefHome) -> URL { home.root.appendingPathComponent("state/app.sock") }
    static func daemonLink(_ home: ChiefHome) -> URL { home.root.appendingPathComponent("state/app-daemon.sock") }

    /// The links the brain host gets (`HomeBrainHost.childEnvironment`).
    static func hostEnvironment(_ home: ChiefHome) -> [String: String] {
        ["CMUX_SOCKET_PATH": controlLink(home).path, "CMUX_APP_DAEMON_SOCKET": daemonLink(home).path]
    }

    /// Points both links at this app (last writer wins), each atomically.
    public static func publish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        let state = home.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        point(controlLink(home), at: controlSocket)
        if let daemonSocket { point(daemonLink(home), at: daemonSocket) }
    }

    /// Removes the links that still point at this app's sockets (another
    /// build that took them over keeps them).
    public static func unpublish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        for (link, target) in [(controlLink(home), controlSocket), (daemonLink(home), daemonSocket)] {
            guard let target, (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target else { continue }
            _ = blockingUnlink(link.path)
        }
    }

    /// A temporary link renamed over the old one, so readers never see none.
    private static func point(_ link: URL, at target: String) {
        let temporary = link.path + ".\(getpid()).tmp"
        _ = blockingUnlink(temporary)
        guard (try? FileManager.checked.createSymbolicLink(atPath: temporary, withDestinationPath: target)) != nil else { return }
        if blockingRename(temporary, link.path) != 0 { _ = blockingUnlink(temporary) }
    }
}
