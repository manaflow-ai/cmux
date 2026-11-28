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
public nonisolated enum ChiefAppLinks {
    /// The links' paths (Rust `chief_home.app_links`).
    private struct Links: Decodable {
        let controlLink: String
        let daemonLink: String
        let stateDirectory: String
        let hostEnvironment: [String: String]
    }

    private static func links(_ home: ChiefHome) -> Links {
        struct Request: Encodable { let root: String }
        if let links: Links = try? ChiefHomeRules().call("app_links", Request(root: home.root.path)) { return links }
        // The rules not running: the same paths, so the host never loses the app.
        let state = home.root.appendingPathComponent("state", isDirectory: true)
        let control = state.appendingPathComponent("app.sock").path, daemon = state.appendingPathComponent("app-daemon.sock").path
        return Links(controlLink: control, daemonLink: daemon, stateDirectory: state.path,
                     hostEnvironment: ["CMUX_SOCKET_PATH": control, "CMUX_APP_DAEMON_SOCKET": daemon])
    }

    static func controlLink(_ home: ChiefHome) -> URL { URL(fileURLWithPath: links(home).controlLink) }
    static func daemonLink(_ home: ChiefHome) -> URL { URL(fileURLWithPath: links(home).daemonLink) }

    /// The links the brain host gets (`HomeBrainHost.childEnvironment`).
    static func hostEnvironment(_ home: ChiefHome) -> [String: String] { links(home).hostEnvironment }

    /// Points both links at this app (last writer wins), each atomically.
    public static func publish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        let state = URL(fileURLWithPath: links(home).stateDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        point(controlLink(home), at: controlSocket)
        if let daemonSocket { point(daemonLink(home), at: daemonSocket) }
    }

    /// Removes the links that still point at this app's sockets (another
    /// build that took them over keeps them).
    public static func unpublish(home: ChiefHome, controlSocket: String, daemonSocket: String?) {
        for (link, target) in [(controlLink(home), controlSocket), (daemonLink(home), daemonSocket)] {
            guard let target, (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target else { continue }
            unlink(link.path)
        }
    }

    /// A temporary link renamed over the old one, so readers never see none.
    private static func point(_ link: URL, at target: String) {
        struct Request: Encodable { let link: String; let pid: Int32 }
        struct Reply: Decodable { let path: String }
        let reply: Reply? = try? ChiefHomeRules().call("app_temporary_link", Request(link: link.path, pid: getpid()))
        let temporary = reply?.path ?? link.path + ".\(getpid()).tmp"
        unlink(temporary)
        guard symlink(target, temporary) == 0 else { return }
        if rename(temporary, link.path) != 0 { unlink(temporary) }
    }
}
