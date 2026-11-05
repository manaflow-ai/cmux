import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemoteView
import Foundation

/// A Cloud machine's desktop (`cmux.rd/1` from its `cmux-rd` host on the agent display) over the
/// owner's Native link: one `link.dial` with service `desktop` per session, run by the bundled
/// `cmux-tui link dial` as a stdio bridge (``DaemonBridge``), as a paired server's owner session
/// is. The link mints a one-time owner link token for the dial and the machine's root receiver
/// verifies it before it hands the stream to the host's root-only socket, so the viewer carries
/// no token and nothing on the machine (the agent's `cmux` user included) can admit a viewer.
nonisolated struct CloudDesktopLinkDial: Equatable, Sendable {
    /// The cmux-link `Service` of a Cloud desktop's rd stream.
    static let service = "desktop"

    /// The machine's link host id (`host_…`), from `cloud.machine.connect_info`.
    let host: String
    /// This Mac's running link's local socket.
    let linkSocket: String

    /// Nil unless `host` is a link host id and `linkSocket` an absolute path.
    init?(host: String, linkSocket: String) {
        guard host.hasPrefix("host_"), host.utf8.count == 25,
              host.utf8.dropFirst(5).allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x7a).contains($0) }),
              linkSocket.hasPrefix("/") else { return nil }
        self.host = host
        self.linkSocket = linkSocket
    }

    /// The bridge's fixed argv (after the bundled `cmux-tui`).
    var arguments: [String] {
        ["link", "dial", "--host", host, "--service", Self.service, "--socket", linkSocket]
    }

    /// The host id `cloud.machine.connect_info {machine}` answered, or nil.
    static func host(fromConnectInfo data: Data) -> String? {
        struct Answer: Decodable { var host: String }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.host
    }

    /// The hello of a Cloud desktop session: service `desktop`, no token (the link admitted the
    /// owner; the host takes only the receiver's connection).
    static func hello(install: String = "cmux-next-\(ProcessInfo.processInfo.processIdentifier)") -> RemoteRdHello {
        RemoteRdHello(user: "cmux", install: install, token: nil, service: service)
    }

    /// The rd byte path of one session: `dial()` names the link host and socket, then the bundled
    /// `cli` bridges the dial. A refused dial (no link, a machine without the `desktop` service,
    /// a policy or token refusal) ends the session, so the pane says it ended.
    static func carrier(cli: URL, dial: @escaping @Sendable () async throws -> CloudDesktopLinkDial) -> RemoteRdStreamCarrier {
        RemoteRdStreamCarrier {
            let target = try await dial()
            let bridge = DaemonBridge(executable: cli.path, arguments: target.arguments)
            let stream = try await Task.detached(priority: .userInitiated) { () throws -> DaemonBridgeStream in
                try bridge.openStream()
            }.value
            return RemoteRdByteStream(read: { await stream.read() }, write: { try await stream.send($0) }, close: { stream.close() })
        }
    }
}

extension AppServices {
    /// The link dial of Cloud machine `machine`'s desktop: this Mac's link (started when it is
    /// not running) and the machine's link host id. Throws when either is missing.
    func cloudDesktopLinkDial(machine: String) async throws -> CloudDesktopLinkDial {
        await cloud.ensureLink()
        let run = CloudAppLinks.runner(local: machines.local)
        let answer = try await run("cloud.machine.connect_info", ["machine": machine], UUID().uuidString, .script)
        guard let host = CloudDesktopLinkDial.host(fromConnectInfo: answer), let socket = cloud.linkSocket,
              let dial = CloudDesktopLinkDial(host: host, linkSocket: socket) else {
            throw CloudLinkError.helperNotRunning(reason: "no link socket or host for the machine's desktop")
        }
        return dial
    }
}
