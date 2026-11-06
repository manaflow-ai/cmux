public import Foundation

/// A machine's exec and file routes, one `cmux cloud api` `machine.io` call each (cmux-tui
/// `cli/cloud_api/machine.rs`): a Worker machine's through `cmux cloud machine-io`'s logic (straight to
/// the provider with a client session when it can, else `/v1/cloud/machines/{id}/...`), the classic
/// client's on `/api/vm/{id}/exec` and `/api/vm/{id}/fs/...`.
extension CloudAPIClient {
    /// Exec runs as the machine's work user (`cmux`), not root, while the file routes still
    /// write as root: true on a Worker machines client (backend cloud-machine-guest.ts).
    public var execRunsAsWorkUser: Bool { !sendsStackSession }

    /// A Worker machine's (the Cloud app server link's) exec and file routes, on the cmux API Worker
    /// (`baseURL`: ``CloudConfiguration/ownerAPIBaseURL(environment:)``), as the person's Stack session
    /// (`accessToken`) in the cmux team `teamID` (`x-cmux-team`; the install token's team claim, the team
    /// the app link lists its machines in), like ``CloudOwnerAPIClient``. Never this Mac's install token:
    /// a Mac install has no execute grant, so the route refuses it with a 403 (cmux-platform#89).
    /// `sessions`: where the client sessions are kept (`cloudRoot/client-sessions`).
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, appVersion: String = "cmux-next",
                                      cli: BundledCmux?, sessions: URL?) -> CloudAPIClient {
        CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, appVersion: appVersion,
                       cli: cli, sessions: sessions)
    }

    /// Runs `command` in the machine's shell. The route caps `timeoutMs` at 15 minutes (5 on a Worker machine).
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await machine("exec", id, ["command": command, "timeout_ms": timeoutMs], timeout: .milliseconds(timeoutMs) + .seconds(5),
                          as: CloudExecResult.self)
    }

    /// Lists a guest directory.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: Decodable { var entries: [CloudFileEntry] }
        return try await machine("dir", id, ["path": path], timeout: .seconds(20), as: List.self).entries
    }

    /// Reads a guest file, its bytes as base64.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await machine("read", id, ["path": path], timeout: .seconds(120), as: CloudFileContents.self)
    }

    /// Writes a guest file atomically.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var fields: [String: any Sendable] = ["path": path, "data_base64": data.base64EncodedString()]
        if let mode { fields["mode"] = mode }
        _ = try await machine("write", id, fields, timeout: .seconds(120))
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await machine("mkdir", id, ["path": path], timeout: .seconds(20))
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await machine("remove", id, ["path": path], timeout: .seconds(120))
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await machine("stat", id, ["path": path], timeout: .seconds(20), as: CloudFileStat.self)
    }

    /// One exec or file operation: its answer's body, or the route's refusal. An answer that never
    /// came is `timedOut`, never sent a second time: an exec or a change may have run.
    private func machine(_ op: String, _ id: String, _ fields: [String: any Sendable], timeout: Duration) async throws -> Data {
        var args = fields
        args["op"] = op
        args["machine"] = id
        if let sessions { args["cache_dir"] = sessions.path }
        return try await call("machine.io", args, timeout: timeout)
    }

    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: any Sendable], timeout: Duration,
                                       as type: T.Type) async throws -> T {
        let data = try await machine(op, id, fields, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw CloudAPIError.decoding("\(op) \(id): \(error)") }
    }
}
