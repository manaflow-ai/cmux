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
    /// A daemon connection through `carrier serve`: its handshake and first connection wait out the
    /// carrier's dial of a cold machine, which serve allows 180 s per connection.
    public static let handshakeDeadline: Duration = .milliseconds(deadlineMs + answerSlackMs)

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

    /// `carrier serve`'s refusal before its ready line, after which it exits (#37278). A path it could not
    /// claim (a live serve's socket or another file there) is `bad_request` naming that path, exit 64: another
    /// cmux serving the machine. `ticket` (exit 2: no API URL or credential) and `handshake` (exit 5: no device
    /// key) keep the dial's wording.
    public static func serveStartError(code: String, detail: String?, socket: String) -> CloudLinkError {
        if code == "bad_request", let detail, detail.contains(socket) { return socketTaken }
        return linkError(code: code, detail: detail)
    }

    /// A refusal line of a ready `carrier serve`: a refused connection's step, or the listener failing for good
    /// (`socket`, exit 6), which ends serve. Nil for `bad_request`, which answers a stdin line serve could not use
    /// (a token it refused), not a connection.
    public static func serveRefusal(code: String, detail: String?) -> CloudLinkError? {
        switch code {
        case "bad_request": nil
        case "socket": .helperNotRunning(reason: "cmux carrier serve stopped listening" + (detail.map { ": \($0)" } ?? ""))
        default: linkError(code: code, detail: detail)
        }
    }

    /// A failed carrier socket ask of the Cloud app server (``CloudCredentialRelay/carrierSocketOp``) as the
    /// carrier step the server maps (first-party-apps/cloud/server/src/link/dial.rs): the code a refused
    /// start named, else `unavailable`. The message is the error's wording; no credential is in either.
    public static func carrierRefusal(_ error: any Error) -> CloudCredentialRelay.CarrierRefusal {
        let text = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        switch error as? CloudLinkError {
        case .failed(let code, let message)?:
            return .init(code: code, message: message.isEmpty ? text : message, retryable: code != "bad_request")
        case .disconnected(let reason)? where reason == "relay":
            return .init(code: "relay", message: text, retryable: true)
        case .notUp(let state)? where state == "parked_timeout":
            return .init(code: "parked_timeout", message: text, retryable: true)
        case .helperNotRunning(let reason)?:
            return .init(code: "unavailable", message: reason.isEmpty ? text : reason, retryable: true)
        default:
            return .init(code: "unavailable", message: text, retryable: true)
        }
    }

    /// Another `carrier serve` holds the session's socket.
    static let socketTaken = CloudLinkError.failed(code: "socket", message: "another cmux is serving this machine's connection socket")

    /// The JSON line `carrier serve` reads on stdin to take a new access token for its next dials.
    public static func tokenLine(_ accessToken: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["access_token": accessToken])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// One machine's carrier for the signed-in person: the bundled CLI and the environment each child reads
    /// as it starts (a fresh access token), for the desktop dial and the session's `carrier serve`. A desktop
    /// connector made with ``CloudCarrierStreams`` holds its dials and streams there, fenced at the
    /// generation it was made in.
    public struct Connector: Sendable {
        /// The bundled `cmux-tui`.
        public let cli: URL
        public let dial: CloudCarrierDial
        public let environment: @Sendable () async throws -> [String: String]
        /// Where ``open()`` holds its dial child and stream, and the end it was made after.
        let streams: CloudCarrierStreams?
        let generation: Int

        /// Nil without the bundled CLI or for an id that is not a machine's.
        /// `stateDirectory`: the build's daemon state directory (nil: cmux-tui's default).
        /// Its children get a token only for the account signed in when it was made: after a sign-out or an
        /// account or team switch (or an end of `streams`), ``environment`` throws ``fenced``, so a carrier
        /// of the old account never gets the new account's token.
        @MainActor
        public init?(machine: String, service: Service, cli: URL?, auth: CloudAuth, platform: URL, team: String?, stateDirectory: URL?,
                     streams: CloudCarrierStreams? = nil) {
            guard let cli, let dial = CloudCarrierDial(machine: machine, service: service) else { return nil }
            let (generation, account) = (streams?.generation ?? 0, auth.accountKey)
            (self.cli, self.dial, self.streams, self.generation) = (cli, dial, streams, generation)
            environment = {
                let current: @Sendable () async -> Bool = { await auth.accountKey == account && (streams?.generation ?? 0) == generation }
                guard await current() else { throw Self.fenced }
                let access: String
                do { access = try await auth.tokens().access } catch { if await current() { throw error }; throw Self.fenced }
                // Checked again after the read: a switch during it hands the token to no one.
                guard await current() else { throw Self.fenced }
                return CloudCarrierDial.environment(platform: platform, accessToken: access, team: team, stateDirectory: stateDirectory)
            }
        }

        init(cli: URL, dial: CloudCarrierDial, streams: CloudCarrierStreams? = nil, environment: @escaping @Sendable () async throws -> [String: String]) {
            (self.cli, self.dial, self.streams, self.environment) = (cli, dial, streams, environment)
            generation = streams?.generation ?? 0
        }

        /// An end of ``streams`` came after this connector was made.
        var isFenced: Bool { streams.map { $0.generation != generation } ?? false }

        /// The refusal of an open an end of ``streams`` fenced.
        static let fenced = CloudLinkError.disconnected(reason: "closed")

        /// Runs one dial and returns the connected stream; throws why the carrier refused it, or ``fenced``
        /// once ``CloudCarrierStreams/endAll()`` ran after this connector was made (the dial child, if one
        /// started, is killed then).
        public func open() async throws -> CloudCarrierStream {
            let (streams, generation) = (self.streams, self.generation)
            // A fenced open asks for no token and spawns nothing.
            guard !isFenced else { throw Self.fenced }
            let bridge = dial.bridge(cli: cli, environment: try await environment())
            guard !isFenced else { throw Self.fenced }
            let (stream, id) = try await Task.detached(priority: .userInitiated) { () throws -> (DaemonBridgeStream, Int?) in
                var id: Int?
                do {
                    let stream = try bridge.openStream { kill in id = streams?.hold(generation: generation, stop: kill) }
                    return (stream, id)
                } catch {
                    if let id { streams?.release(id) }
                    if let streams, streams.generation != generation { throw Self.fenced }
                    throw error
                }
            }.value
            guard let streams else { return CloudCarrierStream(stream: stream) }
            // The dial child became a stream: an end now closes the stream (an end that came first already
            // killed the child, which may have answered just before).
            guard let id, streams.replace(id, stop: { [weak stream] in stream?.close() }) else {
                stream.close()
                throw Self.fenced
            }
            return CloudCarrierStream(stream: stream) { streams.release(id) }
        }
    }
}
