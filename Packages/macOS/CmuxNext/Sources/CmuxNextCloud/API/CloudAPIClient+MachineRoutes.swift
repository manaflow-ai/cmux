public import Foundation

/// A machine's exec and file calls on a Worker machines client
/// (``workerMachines(baseURL:accessToken:teamID:daemon:appVersion:machineIO:installToken:)``): the
/// daemon's `cloud.machine.io` (cmux-cloud-api `machine_io`), which reaches the machine's provider
/// directly with a short-lived client session when it can and cmux-platform's
/// `/v1/cloud/machines/{id}/...` otherwise, as the person's Stack session in the cmux team, never
/// the refresh token. The sign-in client refuses them before any call (``requireWorker(code:)``).
extension CloudAPIClient {
    /// A Worker machine's (the Cloud app server link's) calls on the cmux API Worker (`baseURL`:
    /// ``CloudConfiguration/ownerAPIBaseURL(environment:)``), as the person's Stack session
    /// (`accessToken`) in the cmux team `teamID` (the install token's team claim, the team the app
    /// link lists its machines in), like ``CloudOwnerAPIClient``. Never this Mac's install token: a
    /// Mac install has no execute grant (cmux-platform#89). `machineIO`: the bundled cmux, for the
    /// sealed secret delivery. `installToken`: this Mac's install token, for the one route that
    /// takes an install, not a session (``listNetworks()``).
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, daemon: CloudDaemon, appVersion: String = "cmux-next",
                                      machineIO: CloudMachineIO? = nil,
                                      installToken: (@Sendable () async throws -> String)? = nil) -> CloudAPIClient {
        var client = CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, daemon: daemon,
                                    appVersion: appVersion)
        client.machineIO = machineIO
        client.installToken = installToken
        return client
    }

    /// Runs `command` in the machine's shell. The route caps `timeoutMs` at 5 minutes.
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await machine("exec", id, ["command": command, "timeout_ms": timeoutMs], wait: .milliseconds(timeoutMs) + .seconds(5),
                          as: CloudExecResult.self)
    }

    /// Lists a guest directory.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: CloudServerModel {
            static var cloudModelKind: String { "file_entries" }
            var entries: [CloudFileEntry]
            init(from decoder: any Decoder) throws { entries = try [CloudFileEntry](from: decoder) }
        }
        return try await machine("dir", id, ["path": path], wait: .seconds(20), as: List.self).entries
    }

    /// Reads a guest file; its bytes come back base64.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await machine("read", id, ["path": path], wait: .seconds(120), as: CloudFileContents.self)
    }

    /// Writes a guest file atomically.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var args: [String: any Sendable] = ["path": path, "data_base64": data.base64EncodedString()]
        if let mode { args["mode"] = mode }
        _ = try await machine("write", id, args, wait: .seconds(120))
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await machine("mkdir", id, ["path": path], wait: .seconds(20))
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await machine("remove", id, ["path": path], wait: .seconds(120))
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await machine("stat", id, ["path": path], wait: .seconds(20), as: CloudFileStat.self)
    }

    /// One exec or file operation (`cloud.machine.io` with `op`); refused on the sign-in client.
    private func machine(_ op: String, _ id: String, _ fields: [String: any Sendable], wait: Duration) async throws -> Data {
        try requireWorker()
        var args = fields
        args["op"] = op
        args["machine"] = id
        return try await call("machine.io", args, wait: wait + .seconds(30))
    }

    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: any Sendable], wait: Duration,
                                       as type: T.Type) async throws -> T {
        let path = "/v1/cloud/machines/\(id)/\(op == "exec" ? "exec" : "fs/\(op)")"
        return try CloudMachineRules().answer(try await machine(op, id, fields, wait: wait), as: T.self, context: path)
    }
}
