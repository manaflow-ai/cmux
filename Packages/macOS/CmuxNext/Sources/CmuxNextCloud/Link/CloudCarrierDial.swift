public import CmuxNextDaemon
public import Foundation

/// One `cmux carrier dial --machine <vm_id> --service <service>` (design/cloud-carrier.md), run by the
/// bundled `cmux-tui` as a stdio bridge (``DaemonBridge``) with the platform origin, the person's
/// access token and the machine's team in its environment. Its stderr starts with one JSON answer line;
/// on `ok` its stdin and stdout carry the service. The dial resumes a paused machine, waits out its
/// park and writes its own `<state dir>/carrier/connect.log`; the app only spawns it.
/// - `desktop`: the machine's `cmux-rd` host (`cmux.rd/1`), which serves only the owner's grant.
/// - `mux`: the machine daemon's `cmux.protocol/2` lines; a Cloud session runs it through one
///   `cmux carrier serve` (``CloudCarrierServe``), which dials once per connection to its socket.
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
    /// `CMUX_CLOUD_TEAM` (the machine's team, sent as `x-cmux-team`) when the record names one; and
    /// `CMUX_TUI_STATE_DIR`, the build's daemon state directory (``DaemonLauncher/appNames(build:applicationSupport:log:)``),
    /// under which the dial writes `carrier/connect.log`.
    public static func environment(platform: URL, accessToken: String, team: String?, stateDirectory: URL? = nil) -> [String: String] {
        var environment = ["CMUX_CLOUD_API_URL": platform.absoluteString, "CMUX_CLOUD_ACCESS_TOKEN": accessToken]
        if let team, !team.isEmpty { environment["CMUX_CLOUD_TEAM"] = team }
        if let stateDirectory { environment["CMUX_TUI_STATE_DIR"] = stateDirectory.path }
        return environment
    }

    /// The bridge of one dial through the bundled `cli`: it waits for the answer line as long as the dial's deadline.
    public func bridge(cli: URL, environment: [String: String]) -> DaemonBridge {
        DaemonBridge(executable: cli.path, arguments: arguments, environment: environment,
                     replyTimeoutMs: Int32(Self.deadlineMs + Self.answerSlackMs))
    }

    /// `cmux carrier serve`'s argv: a 0600 socket at `socket` that dials this machine's `mux` once per
    /// connection it accepts, for the Cloud session's daemon connection and every CLI call to that daemon.
    public func serveArguments(socket: String) -> [String] {
        ["carrier", "serve", "--machine", machine, "--socket", socket]
    }

    /// One stderr line of `carrier serve`: its ready line, or a refusal (before it is ready, why it exits;
    /// after, one refused connection's dial). Nil for anything else.
    public enum ServeLine: Equatable, Sendable {
        case ready(socket: String)
        /// One connection's dial got through; `vmk` is the grant's `owner` or `team`, nil when it had none.
        case connected(vmk: String?)
        case refused(code: String, detail: String?)
    }

    /// Reads `{"ok":true,"socket":PATH,"route":"carrier"}`, `{"ok":true,"route":"carrier","vmk"?:…}` or
    /// `{"ok":false,"error_code":…,"error_detail"?:…}`.
    public static func serveLine(_ line: String) -> ServeLine? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        if object["ok"] as? Bool == true {
            if let socket = object["socket"] as? String, !socket.isEmpty { return .ready(socket: socket) }
            return .connected(vmk: object["vmk"] as? String)
        }
        guard object["ok"] as? Bool == false, let code = object["error_code"] as? String else { return nil }
        return .refused(code: code, detail: object["error_detail"] as? String)
    }

    /// A refused dial as the link wording the sidebar already has, step by step: `relay` dropped,
    /// `parked_timeout` not ready yet (the machine's daemon never registered), any other step (`ticket`,
    /// `handshake`) a failed connect naming it.
    public static func linkError(code: String, detail: String?) -> CloudLinkError {
        switch code {
        case "relay": .disconnected(reason: code)
        case "parked_timeout": .notUp(state: code)
        default: .failed(code: code, message: detail.map { "\(code): \($0)" } ?? "")
        }
    }

    /// The JSON line `carrier serve` reads on stdin to take a new access token for its next dials.
    public static func tokenLine(_ accessToken: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["access_token": accessToken])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// One machine's carrier for the signed-in person: the bundled CLI and the environment each child reads
    /// as it starts (a fresh access token), for the desktop dial and the session's `carrier serve`.
    public struct Connector: Sendable {
        /// The bundled `cmux-tui`.
        public let cli: URL
        public let dial: CloudCarrierDial
        public let environment: @Sendable () async throws -> [String: String]

        /// Nil without the bundled CLI or for an id that is not a machine's.
        /// `stateDirectory`: the build's daemon state directory (nil: cmux-tui's default).
        public init?(machine: String, service: Service, cli: URL?, auth: CloudAuth, platform: URL, team: String?, stateDirectory: URL?) {
            guard let cli, let dial = CloudCarrierDial(machine: machine, service: service) else { return nil }
            (self.cli, self.dial) = (cli, dial)
            environment = {
                CloudCarrierDial.environment(platform: platform, accessToken: try await auth.tokens().access, team: team, stateDirectory: stateDirectory)
            }
        }

        init(cli: URL, dial: CloudCarrierDial, environment: @escaping @Sendable () async throws -> [String: String]) {
            (self.cli, self.dial, self.environment) = (cli, dial, environment)
        }

        /// Runs one dial and returns the connected stream; throws why the carrier refused it.
        public func open() async throws -> DaemonBridgeStream {
            let bridge = dial.bridge(cli: cli, environment: try await environment())
            return try await Task.detached(priority: .userInitiated) { () throws -> DaemonBridgeStream in
                try bridge.openStream()
            }.value
        }
    }
}
