public import CmuxNextDaemon
public import Foundation

/// One `cmux carrier dial --machine <vm_id> --service <service>` (design/cloud-carrier.md), run by the
/// bundled `cmux-tui` as a stdio bridge (``DaemonBridge``) with the platform origin, the person's
/// access token and the machine's team in its environment. Its stderr starts with one JSON answer line;
/// on `ok` its stdin and stdout carry the service. The dial resumes a paused machine, waits out its
/// park and writes its own `<state dir>/carrier/connect.log`; the app only spawns it.
/// - `desktop`: the machine's `cmux-rd` host (`cmux.rd/1`), which serves only the owner's grant.
/// - `mux`: the machine daemon's `cmux.protocol/2` lines, one daemon connection per dial.
public struct CloudCarrierDial: Equatable, Sendable {
    /// The carrier service a dial opens.
    public enum Service: String, Sendable {
        case desktop, mux
    }

    /// The dial's one deadline (the carrier's default): a paused machine resumes and registers inside it.
    static let deadlineMs = 180_000
    /// ``DaemonBridge`` waits for the answer line this much past the dial's deadline, so the dial's own
    /// refusal (`parked_timeout`) arrives instead of the bridge's "no answer".
    static let answerSlackMs = 2_000

    /// The machine's id (`vm_…`).
    public let machine: String
    public let service: Service

    /// Nil for an empty id or one with characters an id never has.
    public init?(machine: String, service: Service) {
        guard !machine.isEmpty, machine.utf8.count <= 128,
              machine.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x7a).contains($0) || (0x41...0x5a).contains($0) || $0 == 0x5f || $0 == 0x2d })
        else { return nil }
        self.machine = machine
        self.service = service
    }

    /// The bridge's fixed argv (after the bundled `cmux-tui`).
    public var arguments: [String] {
        ["carrier", "dial", "--machine", machine, "--service", service.rawValue, "--deadline-ms", String(Self.deadlineMs)]
    }

    /// The dial's credential: `CMUX_CLOUD_API_URL` (the platform origin), `CMUX_CLOUD_ACCESS_TOKEN`, and
    /// `CMUX_CLOUD_TEAM` (the machine's team, sent as `x-cmux-team`) when the record names one.
    public static func environment(platform: URL, accessToken: String, team: String?) -> [String: String] {
        var environment = ["CMUX_CLOUD_API_URL": platform.absoluteString, "CMUX_CLOUD_ACCESS_TOKEN": accessToken]
        if let team, !team.isEmpty { environment["CMUX_CLOUD_TEAM"] = team }
        return environment
    }

    /// The bridge of one dial through the bundled `cli`: it waits for the answer line as long as the dial's deadline.
    public func bridge(cli: URL, environment: [String: String]) -> DaemonBridge {
        DaemonBridge(executable: cli.path, arguments: arguments, environment: environment,
                     replyTimeoutMs: Int32(Self.deadlineMs + Self.answerSlackMs))
    }

    /// A new bridge for each connection, with the environment read as it opens (a fresh access token).
    public func bridging(cli: URL, environment: @escaping @Sendable () async throws -> [String: String])
        -> @Sendable () async throws -> DaemonBridge {
        { [self] in bridge(cli: cli, environment: try await environment()) }
    }

    /// One machine's dial for the signed-in person, spawned anew for each connection with a fresh access
    /// token: the Cloud session's daemon connections (`mux`) and the desktop viewer (`desktop`) both run it.
    public struct Connector: Sendable {
        /// The bundled `cmux-tui`.
        public let cli: URL
        public let bridging: @Sendable () async throws -> DaemonBridge

        /// Nil without the bundled CLI or for an id that is not a machine's.
        public init?(machine: String, service: Service, cli: URL?, auth: CloudAuth, platform: URL, team: String?) {
            guard let cli, let dial = CloudCarrierDial(machine: machine, service: service) else { return nil }
            self.cli = cli
            bridging = dial.bridging(cli: cli) {
                CloudCarrierDial.environment(platform: platform, accessToken: try await auth.tokens().access, team: team)
            }
        }

        /// Runs one dial and returns the connected stream; throws why the carrier refused it.
        public func open() async throws -> DaemonBridgeStream {
            let bridge = try await bridging()
            return try await Task.detached(priority: .userInitiated) { () throws -> DaemonBridgeStream in
                try bridge.openStream()
            }.value
        }
    }

    /// A refused dial as the link error the Cloud sidebar already words, step by step: `ticket` (the
    /// platform minted no ticket) and `handshake` (the machine's end did not answer) as a failed connect,
    /// `relay` as a dropped one, `parked_timeout` (the machine did not wake in time) as not ready, and
    /// `service_refused` (not this caller's machine) as a failed connect naming the code. Nil for anything
    /// that is not a carrier refusal.
    public static func linkError(_ error: DaemonError?) -> CloudLinkError? {
        guard let error, let code = DaemonBridge.refusedCode(error) else { return nil }
        return switch code {
        case "relay": .disconnected(reason: code)
        case "parked_timeout": .notUp(state: code)
        default: .failed(code: code, message: "")
        }
    }
}
