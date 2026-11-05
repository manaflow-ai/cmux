public import CmuxNextDaemon
public import Foundation

/// A Cloud machine's desktop (`cmux.rd/1` from its `cmux-rd` host on the agent display) over the
/// owner's Native link: one `link.dial` with service `desktop` per session, run by the bundled
/// `cmux-tui link dial` as a stdio bridge (``DaemonBridge``), as a paired server's owner session
/// is. The link mints a one-time owner link token for the dial and the machine's root receiver
/// verifies it before it hands the stream to the host's root-only socket, so the viewer carries
/// no token and nothing on the machine (the agent's `cmux` user included) can admit a viewer.
public struct CloudDesktopLinkDial: Equatable, Sendable {
    /// The cmux-link `Service` of a Cloud desktop's rd stream.
    public static let service = "desktop"
    /// The Cloud app server op that names the machine's link host id.
    public static let connectInfoOp = "cloud.machine.connect_info"

    /// The machine's link host id (`host_…`), from `cloud.machine.connect_info`.
    public let host: String
    /// This Mac's running link's local socket.
    public let linkSocket: String

    /// Nil unless `host` is a link host id and `linkSocket` an absolute path.
    public init?(host: String, linkSocket: String) {
        guard host.hasPrefix("host_"), host.utf8.count == 25,
              host.utf8.dropFirst(5).allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x7a).contains($0) }),
              linkSocket.hasPrefix("/") else { return nil }
        self.host = host
        self.linkSocket = linkSocket
    }

    /// The dial of `connect_info`'s answer through `linkSocket`, or nil.
    public init?(connectInfo data: Data, linkSocket: String?) {
        struct Answer: Decodable { var host: String }
        guard let host = (try? JSONDecoder().decode(Answer.self, from: data))?.host, let linkSocket else { return nil }
        self.init(host: host, linkSocket: linkSocket)
    }

    /// The bridge's fixed argv (after the bundled `cmux-tui`).
    public var arguments: [String] {
        ["link", "dial", "--host", host, "--service", Self.service, "--socket", linkSocket]
    }

    /// Runs the dial through the bundled `cli` and returns the connected stream; throws why the
    /// link refused it (no link, a machine without the `desktop` service, a policy or token refusal).
    public func open(cli: URL) async throws -> DaemonBridgeStream {
        let bridge = DaemonBridge(executable: cli.path, arguments: arguments)
        return try await Task.detached(priority: .userInitiated) { () throws -> DaemonBridgeStream in
            try bridge.openStream()
        }.value
    }
}

public extension CloudMachine {
    /// Open Desktop's viewer when none is named: `rd` for a machine whose capabilities declare
    /// `desktop` (its image carries the `cmux-rd` host on the agent display), `web` (noVNC) for
    /// one that declares none (classic, which keeps its own desktop).
    var defaultDesktopViewer: String { capabilities.desktop ? "rd" : "web" }
}
