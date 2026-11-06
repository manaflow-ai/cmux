public import CmuxNextDaemon
public import Foundation

/// A Cloud machine's desktop (`cmux.rd/1` from its `cmux-rd` host on the agent display) over the
/// carrier (design/cloud-carrier.md): one `cmux carrier dial --machine <vm_id> --service desktop`
/// per session, run by the bundled `cmux-tui` as a stdio bridge (``DaemonBridge``) with the
/// platform origin, the person's access token and the machine's team in its environment. The machine's daemon opens
/// the desktop socket only for the owner's grant; anyone else's dial answers `service_refused`
/// (exit 6), so the viewer carries no token of its own.
public struct CloudDesktopLinkDial: Equatable, Sendable {
    /// The carrier dial's service for a Cloud desktop's rd stream.
    public static let service = "desktop"
    /// The dial's one deadline (the carrier's default): a paused machine resumes and registers inside it.
    static let deadlineMs = 180_000
    /// ``DaemonBridge`` waits for the answer line this much past the dial's deadline, so the dial's own
    /// refusal (`deadline`) arrives instead of the bridge's "no answer".
    static let answerSlackMs = 2_000

    /// The machine's id (`vm_…`).
    public let machine: String

    /// Nil for an empty id or one with characters an id never has.
    public init?(machine: String) {
        guard !machine.isEmpty, machine.utf8.count <= 128,
              machine.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x7a).contains($0) || (0x41...0x5a).contains($0) || $0 == 0x5f || $0 == 0x2d })
        else { return nil }
        self.machine = machine
    }

    /// The bridge's fixed argv (after the bundled `cmux-tui`).
    public var arguments: [String] {
        ["carrier", "dial", "--machine", machine, "--service", Self.service, "--deadline-ms", String(Self.deadlineMs)]
    }

    /// The dial's credential: `CMUX_CLOUD_API_URL` (the platform origin), `CMUX_CLOUD_ACCESS_TOKEN`, and
    /// `CMUX_CLOUD_TEAM` (the machine's team, sent as `x-cmux-team`) when the record names one.
    public static func environment(platform: URL, accessToken: String, team: String?) -> [String: String] {
        var environment = ["CMUX_CLOUD_API_URL": platform.absoluteString, "CMUX_CLOUD_ACCESS_TOKEN": accessToken]
        if let team, !team.isEmpty { environment["CMUX_CLOUD_TEAM"] = team }
        return environment
    }

    /// Runs the dial through the bundled `cli` and returns the connected stream; throws why the
    /// carrier refused it (no ticket, no relay, `service_refused` for a caller who is not the owner).
    public func open(cli: URL, environment: [String: String]) async throws -> DaemonBridgeStream {
        let bridge = DaemonBridge(executable: cli.path, arguments: arguments, environment: environment,
                                  replyTimeoutMs: Int32(Self.deadlineMs + Self.answerSlackMs))
        return try await Task.detached(priority: .userInitiated) { () throws -> DaemonBridgeStream in
            try bridge.openStream()
        }.value
    }
}
