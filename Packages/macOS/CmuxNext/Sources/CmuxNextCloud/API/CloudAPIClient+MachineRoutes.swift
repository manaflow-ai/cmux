public import Foundation

/// A machine's exec and file routes: `/api/vm/{id}/exec` and `/api/vm/{id}/fs/...` on the classic
/// client, the same requests and answers under `/v1/cloud/machines/{id}/` on a Worker machines
/// client (``workerMachines(baseURL:accessToken:teamID:session:appVersion:)``). The classic client
/// sends the Stack refresh token and `X-Cmux-Team-Id`; a Worker machines client sends the Stack
/// access token and the cmux team in `x-cmux-team`, never the refresh token.
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
    /// the machine's provider directly with a client session when it can and the same routes here
    /// otherwise; a cmux-tui that gives no answer falls back to these routes.
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, session: URLSession = CloudAPIClient.noStoreTransport,
                                      appVersion: String = "cmux-next", machineIO: CloudMachineIO? = nil) -> CloudAPIClient {
        var client = CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, session: session,
                                    appVersion: appVersion)
        client.machineIO = machineIO
        return client
    }

    /// `POST /api/vm/{id}/exec`: runs `command` in the machine's shell. The
    /// route caps `timeoutMs` at 15 minutes (5 on a Worker machine).
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await machine("exec", id, ["command": command, "timeoutMs": timeoutMs], timeout: .milliseconds(timeoutMs) + .seconds(5)) {
            try await send("POST", "\(machinePath)/\(id)/exec", body: ["command": command, "timeoutMs": timeoutMs],
                           timeout: .milliseconds(timeoutMs) + .seconds(5), as: CloudExecResult.self)
        }
    }

    /// Lists a guest directory through the authenticated backend wrapper.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: Decodable { var entries: [CloudFileEntry] }
        return try await machine("dir", id, ["path": path], timeout: .seconds(20)) {
            try await send("GET", "\(machinePath)/\(id)/fs/dir?path=\(query(path))", as: List.self)
        }.entries
    }

    /// Reads a guest file. The backend encodes bytes as base64 for this JSON API.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await machine("read", id, ["path": path], timeout: .seconds(120)) {
            try await send("GET", "\(machinePath)/\(id)/fs/read?path=\(query(path))", timeout: .seconds(120), as: CloudFileContents.self)
        }
    }

    /// Writes a guest file atomically through the backend wrapper.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        let encoded = data.base64EncodedString()
        var body: [String: any Sendable] = ["path": path, "dataBase64": encoded]
        var request: [String: any Sendable] = ["path": path, "data_base64": encoded]
        if let mode {
            body["mode"] = mode
            request["mode"] = mode
        }
        _ = try await machine("write", id, request, timeout: .seconds(120)) {
            try await send("POST", "\(machinePath)/\(id)/fs/write", body: body, timeout: .seconds(120), as: Ignored.self)
        }
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await machine("mkdir", id, ["path": path], timeout: .seconds(20)) {
            try await send("POST", "\(machinePath)/\(id)/fs/mkdir", body: ["path": path], as: Ignored.self)
        }
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await machine("remove", id, ["path": path], timeout: .seconds(120)) {
            try await send("DELETE", "\(machinePath)/\(id)/fs/remove?path=\(query(path))", timeout: .seconds(120), as: Ignored.self)
        }
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await machine("stat", id, ["path": path], timeout: .seconds(20)) {
            try await send("GET", "\(machinePath)/\(id)/fs/stat?path=\(query(path))", as: CloudFileStat.self)
        }
    }

    /// One exec or file operation: through ``machineIO`` on a Worker machines client that has one,
    /// decoded exactly as the route's own answer (a refusal throws what ``send`` would), else (no
    /// cmux-tui, or one that gave no answer) through `http`, the route itself.
    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: any Sendable], timeout: Duration,
                                       http: () async throws -> T) async throws -> T {
        guard let machineIO, !sendsStackSession else { return try await http() }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        var request = fields
        request["op"] = op
        request["machine"] = id
        request["api"] = baseURL.absoluteString
        request["credential"] = access
        request["app_version"] = appVersion
        if let team = await teamID() { request["team"] = team }
        if op == "exec", let ms = fields["timeoutMs"] as? Int {
            request.removeValue(forKey: "timeoutMs")
            request["timeout_ms"] = ms
        }
        let answer: CloudMachineIO.Answer
        do {
            // The child's own HTTP deadlines end first; this one only bounds a child that hangs.
            answer = try await machineIO.perform(request, timeout: timeout + .seconds(30))
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            // Only what cannot have changed the machine goes again over HTTP: a call cmux never took,
            // or a read. An exec or a change that may have run is reported, never made twice.
            guard noAnswer.dispatched, !["dir", "read", "stat"].contains(op) else { return try await http() }
            throw CloudAPIError.transport("cmux did not answer; the \(op) may have run")
        }
        let path = "\(machinePath)/\(id)/\(op == "exec" ? "exec" : "fs/\(op)")"
        switch answer.status {
        case 0 where answer.code == "timed_out": throw CloudAPIError.timedOut(path)
        case 0: throw CloudAPIError.transport(answer.code ?? "no answer")
        case 200..<300:
            if T.self == Ignored.self, let ignored = Ignored() as? T { return ignored }
            do { return try JSONDecoder().decode(T.self, from: answer.body) } catch { throw CloudAPIError.decoding("\(path): \(error)") }
        default:
            throw CloudAPIError.from(status: answer.status, data: answer.body, headerCode: answer.code)
        }
    }
}
