public import Foundation
import CmuxNextDaemon

/// A machine's exec and file routes (the daemon's `cloud.machine.io`): `/api/vm/{id}/exec` and
/// `/api/vm/{id}/fs/...` on the classic client, the same requests and answers under
/// `/v1/cloud/machines/{id}/` on a Worker machines client
/// (``workerMachines(baseURL:accessToken:teamID:caller:appVersion:machineIO:)``). The classic
/// client sends the Stack refresh token and `X-Cmux-Team-Id`; a Worker machines client sends the
/// Stack access token and the cmux team in `x-cmux-team`, never the refresh token.
extension CloudAPIClient {
    /// Exec runs as the machine's work user (`cmux`), not root, while the file routes still
    /// write as root: true on a Worker machines client (backend cloud-machine-guest.ts).
    public var execRunsAsWorkUser: Bool { !sendsStackSession }

    /// A Worker machine's (the Cloud app server link's) exec and file routes: the same requests
    /// and answers as `/api/vm/{id}/exec` and `/api/vm/{id}/fs/...`, under
    /// `/v1/cloud/machines/{id}/` on the cmux API Worker (`baseURL`:
    /// ``CloudConfiguration/ownerAPIBaseURL(environment:)``), as the person's Stack session
    /// (`accessToken`) in the cmux team `teamID` (`x-cmux-team`; the install token's team claim,
    /// the team the app link lists its machines in), like ``CloudOwnerAPIClient``. Never this Mac's
    /// install token: a Mac install has no execute grant, so the route refuses it with a 403
    /// (cmux-platform#89, backend cloud-machine-guest.ts). Only those routes serve there.
    /// `machineIO`: its exec and file routes go through cmux-tui (``CloudMachineIO``), which reaches
    /// the machine's provider directly with a client session (kept between calls) when it can;
    /// a cmux-tui that gives no answer falls back to the daemon's call of these routes.
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, caller: CloudAPICaller,
                                      appVersion: String = "cmux-next", machineIO: CloudMachineIO? = nil) -> CloudAPIClient {
        var client = CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, caller: caller,
                                    appVersion: appVersion)
        client.machineIO = machineIO
        return client
    }

    /// Runs `command` in the machine's shell. The route caps `timeoutMs` at 15 minutes (5 on a
    /// Worker machine).
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await machine("exec", id, ["command": .string(command), "timeout_ms": .number(Double(timeoutMs))],
                          timeout: .milliseconds(timeoutMs) + .seconds(5), as: CloudExecResult.self)
    }

    /// Lists a guest directory through the authenticated backend wrapper.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: CloudServerModel {
            static var cloudModelKind: String { "file_entries" }
            var entries: [CloudFileEntry]
            init(from decoder: any Decoder) throws { entries = try [CloudFileEntry](from: decoder) }
        }
        return try await machine("dir", id, ["path": .string(path)], timeout: .seconds(20), as: List.self).entries
    }

    /// Reads a guest file. The backend encodes bytes as base64 for this JSON API.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await machine("read", id, ["path": .string(path)], timeout: .seconds(120), as: CloudFileContents.self)
    }

    /// Writes a guest file atomically through the backend wrapper.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        let encoded = data.base64EncodedString()
        var request: [String: JSONValue] = ["path": .string(path), "data_base64": .string(encoded)]
        if let mode { request["mode"] = .number(Double(mode)) }
        // A body past one daemon request goes to the route itself, so every write the route takes
        // still goes (`cmux cloud machine-io` reads stdin whole, so a Worker client's goes there first).
        var route: (@Sendable () async throws -> Ignored)?
        if encoded.utf8.count > Self.daemonWriteLimit {
            route = { [self] in try await postWrite(id, path: path, encoded: encoded, mode: mode) }
        }
        _ = try await machine("write", id, request, timeout: .seconds(120), as: Ignored.self, route: route)
    }

    /// The most base64 one write sends through the daemon: its requests are at most 4 MiB
    /// (cmux-tui `resource::MAX_MESSAGE_BYTES`), less room for the envelope and the credentials.
    static let daemonWriteLimit = (4 << 20) - (128 << 10)

    /// `POST .../fs/write` straight to the route, with the headers the daemon's call would send.
    private func postWrite(_ id: String, path: String, encoded: String, mode: Int?) async throws -> Ignored {
        let credentials = try await credentials()
        let route = "\(sendsStackSession ? "/api/vm" : "/v1/cloud/machines")/\(id)/fs/write"
        guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + route) else {
            throw CloudAPIError.transport("not a Cloud machine id")
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        request.setValue("cmux-mac", forHTTPHeaderField: "X-Cmux-Client")
        request.setValue(appVersion, forHTTPHeaderField: "X-Cmux-App-Version")
        if let refresh = credentials.refresh { request.setValue(refresh, forHTTPHeaderField: "X-Stack-Refresh-Token") }
        if let team = credentials.team { request.setValue(team, forHTTPHeaderField: sendsStackSession ? "X-Cmux-Team-Id" : "x-cmux-team") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["path": path, "dataBase64": encoded]
        if let mode { body["mode"] = mode }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fileRoute.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(route)
        } catch let error as URLError where backendIsLocalOnly && error.code == .cannotConnectToHost {
            throw CloudAPIError.noBackend(baseURL)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudAPIError.from(status: http.statusCode, data: data, headerCode: http.value(forHTTPHeaderField: "x-cmux-vm-error"))
        }
        return Ignored()
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await machine("mkdir", id, ["path": .string(path)], timeout: .seconds(20), as: Ignored.self)
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await machine("remove", id, ["path": .string(path)], timeout: .seconds(120), as: Ignored.self)
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await machine("stat", id, ["path": .string(path)], timeout: .seconds(20), as: CloudFileStat.self)
    }

    /// An answer that is not read.
    struct Ignored: Decodable, Sendable {}

    /// One exec or file operation: through ``machineIO`` on a Worker machines client that has one,
    /// decoded exactly as the route's own answer (a refusal throws what the route's would), else
    /// (a classic client, no cmux-tui, or one that gave no answer) the daemon's `machine.io`.
    /// `route`: the call too large for the daemon, sent in its place.
    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: JSONValue], timeout: Duration,
                                       as type: T.Type, route: (@Sendable () async throws -> T)? = nil) async throws -> T {
        var args = fields
        args["op"] = .string(op)
        args["machine"] = .string(id)
        // A Worker machine's call through the daemon takes the cmux API's own route, as it did when
        // the app sent it itself: the daemon keeps no client session between calls.
        let viaDaemon = { [self] () async throws -> T in
            if let route { return try await route() }
            var sent = args
            if !sendsStackSession { sent["route"] = .string("proxy") }
            if T.self == Ignored.self, let ignored = Ignored() as? T {
                _ = try await call("machine.io", sent, timeout: timeout)
                return ignored
            }
            return try await call("machine.io", sent, timeout: timeout, as: T.self)
        }
        guard let machineIO, !sendsStackSession else { return try await viaDaemon() }
        let credentials = try await credentials()
        var request: [String: any Sendable] = args.compactMapValues(\.machineIOValue)
        request["api"] = baseURL.absoluteString
        request["credential"] = credentials.access
        request["app_version"] = appVersion
        if let team = credentials.team { request["team"] = team }
        let answer: CloudMachineIO.Answer
        do {
            // The child's own HTTP deadlines end first; this one only bounds a child that hangs.
            answer = try await machineIO.perform(request, timeout: timeout + .seconds(30))
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            // Only what cannot have changed the machine goes again, through the cmux API's route:
            // a call cmux never took, or a read. An exec or a change that may have run is reported,
            // never made twice.
            guard noAnswer.dispatched, !["dir", "read", "stat"].contains(op) else { return try await viaDaemon() }
            throw CloudAPIError.transport("cmux did not answer; the \(op) may have run")
        }
        let path = "/v1/cloud/machines/\(id)/\(op == "exec" ? "exec" : "fs/\(op)")"
        switch answer.status {
        case 0 where answer.code == "timed_out": throw CloudAPIError.timedOut(path)
        case 0: throw CloudAPIError.transport(answer.code ?? "no answer")
        case 200..<300:
            if T.self == Ignored.self, let ignored = Ignored() as? T { return ignored }
            return try CloudMachineRules().answer(answer.body, as: T.self, context: path)
        default:
            throw CloudAPIError.from(status: answer.status, data: answer.body, headerCode: answer.code)
        }
    }
}

private extension JSONValue {
    /// A scalar field as `cmux cloud machine-io`'s stdin JSON takes it (the machine calls send no other kind).
    var machineIOValue: (any Sendable)? {
        switch self {
        case let .string(text): text
        case let .bool(flag): flag
        case let .number(number): number.rounded() == number && abs(number) < 1e15 ? Int(number) : number
        default: nil
        }
    }
}
