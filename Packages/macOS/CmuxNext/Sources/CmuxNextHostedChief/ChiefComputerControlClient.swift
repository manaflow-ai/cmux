public import CmuxNextHomeEngine
public import Foundation

/// A Cloud Chief's own computer's control lease through the Worker's owner routes (backend
/// chief-brain/routes.ts, chief-brain-cc/sandbox-computer.ts), as its signed-in owner, over the same
/// brain route the profile's status and screen reads use (``HomeChiefComputerRoute``):
///
/// - `GET  v1/chiefs/<agent>/computer` answers `{ok, value: {…, control: {holder, since_ms, reason?}, entitled}}`.
/// - `POST v1/chiefs/<agent>/computer/control` `{action: take_over | hand_back}` answers `{ok, value: {control}}`.
/// - `POST v1/chiefs/<agent>/computer/input` `{op, x?, y?, to_x?, to_y?, button?, count?, text?, keys?,
///   direction?, amount?, url?}` runs one input while the person holds control and answers `{done, control}`
///   (409 `computer.not_human` otherwise).
///
/// The control and input routes take only the owner's signed-in session (403 `computer.user_origin_required`
/// for an install token or a Chief's grant): the brain route sends the signed-in user's access token.
///
/// A refusal answers `{ok: false, error: {code, message}}` and throws ``Failure``.
public struct ChiefComputerControlClient: Sendable {
    /// What the status route says about control.
    public struct Snapshot: Equatable, Sendable {
        public var control: HomeChiefComputerControlState?
        public var entitled: Bool?
    }

    /// A refused or failed request: the HTTP status and the route's error code and message.
    public nonisolated struct Failure: LocalizedError, Equatable {
        public var status: Int
        public var code: String?
        public var message: String?

        /// The person no longer holds control (the Chief took it back, or never gave it).
        public var isNotHuman: Bool { code == "computer.not_human" }

        public var errorDescription: String? {
            message ?? String(localized: "cloud.computerControl.noAnswer", defaultValue: "The Chief's computer did not answer. Try again in a moment.", table: "HostedChief", bundle: .module)
        }
    }

    /// A take-over request.
    public enum ControlAction: String, Sendable {
        case takeOver = "take_over"
        case handBack = "hand_back"
    }

    let send: HomeChiefHostedEngine.Send

    public init(send: @escaping HomeChiefHostedEngine.Send) {
        self.send = send
    }

    /// Whether `agent` is an agent id the routes take (`agent_` and its ULID); anything else never
    /// reaches a path.
    public static func isAgentID(_ agent: String) -> Bool {
        agent.hasPrefix("agent_") && agent.count <= 64 && agent.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }
    }

    /// The agent whose status route `path` is (`v1/chiefs/<agent>/computer`), else nil.
    public static func agent(ofStatusPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "v1", parts[1] == "chiefs", parts[3] == "computer" else { return nil }
        let agent = String(parts[2])
        return isAgentID(agent) ? agent : nil
    }

    // MARK: Requests

    @MainActor
    public func status(agent: String) async throws -> Snapshot {
        let value = try await request("GET", agent, "computer", body: nil)
        return Self.snapshot(value)
    }

    @MainActor
    public func control(agent: String, _ action: ControlAction) async throws -> HomeChiefComputerControlState {
        let value = try await request("POST", agent, "computer/control", body: ["action": action.rawValue])
        guard let state = Self.controlState(value["control"]) else { throw Failure(status: 200, code: "bad_reply", message: nil) }
        return state
    }

    /// Runs one input; answers the lease the route reports with it (`{done, control}`), nil when it reports none.
    @MainActor
    public func input(agent: String, _ input: HomeChiefComputerInput) async throws -> HomeChiefComputerControlState? {
        let value = try await request("POST", agent, "computer/input", body: Self.inputBody(input))
        return Self.controlState(value["control"])
    }

    @MainActor
    private func request(_ method: String, _ agent: String, _ route: String, body: [String: Any]?) async throws -> [String: Any] {
        guard Self.isAgentID(agent) else { throw Failure(status: 0, code: "not_found", message: nil) }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let reply = try await send(method, "v1/chiefs/\(agent)/\(route)", data)
        let root = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
        guard (200..<300).contains(reply.status), root["ok"] as? Bool == true else {
            let error = root["error"] as? [String: Any]
            throw Failure(status: reply.status, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        return root["value"] as? [String: Any] ?? [:]
    }

    // MARK: JSON

    /// The status route's reply body as a snapshot; nil for anything but `{ok: true, value}`.
    public static func statusSnapshot(_ body: Data) -> Snapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], root["ok"] as? Bool == true,
              let value = root["value"] as? [String: Any] else { return nil }
        return snapshot(value)
    }

    static func snapshot(_ value: [String: Any]) -> Snapshot {
        Snapshot(control: controlState(value["control"]), entitled: value["entitled"] as? Bool)
    }

    /// `{holder, since_ms, reason?}`; nil for an unknown holder or another shape.
    static func controlState(_ json: Any?) -> HomeChiefComputerControlState? {
        guard let object = json as? [String: Any], let holder = (object["holder"] as? String).flatMap(HomeChiefComputerHolder.init(rawValue:)) else { return nil }
        let since = (object["since_ms"] as? NSNumber)?.int64Value ?? 0
        let reason = (object["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HomeChiefComputerControlState(holder: holder, sinceMs: since, reason: reason)
    }

    /// A button number in xdotool's order (1 left, 2 middle, 3 right) as the route names it.
    static func buttonName(_ button: Int) -> String {
        switch button {
        case 2: "middle"
        case 3: "right"
        default: "left"
        }
    }

    /// One input as the input route takes it.
    public static func inputBody(_ input: HomeChiefComputerInput) -> [String: Any] {
        switch input {
        case .click(let x, let y, let button, let count):
            ["op": "click", "x": x, "y": y, "button": buttonName(button), "count": count]
        case .move(let x, let y):
            ["op": "move", "x": x, "y": y]
        case .drag(let fromX, let fromY, let toX, let toY):
            ["op": "drag", "x": fromX, "y": fromY, "to_x": toX, "to_y": toY]
        case .scroll(let x, let y, let direction, let amount):
            ["op": "scroll", "x": x, "y": y, "direction": direction, "amount": amount]
        case .type(let text):
            ["op": "type", "text": text]
        case .key(let keys):
            ["op": "key", "keys": keys]
        }
    }

    /// `send`, with each status read's lease (`GET v1/chiefs/<agent>/computer`'s `control` and
    /// `entitled`) handed to `store`: the profile tab's own status cadence keeps its Take Over bar
    /// current, with no read of its own.
    public static func feeding(_ send: @escaping HomeChiefHostedEngine.Send, into store: ChiefComputerControlStore) -> HomeChiefHostedEngine.Send {
        { [weak store] method, path, body in
            let reply = try await send(method, path, body)
            if method == "GET", reply.status == 200, let agent = agent(ofStatusPath: path) {
                store?.ingest(agent: agent, statusBody: reply.body)
            }
            return reply
        }
    }
}
