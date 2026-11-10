import CmuxNextCompat
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

    /// Reads a guest file. Its bytes come through a file of the app's (the path form of
    /// `cloud.machine.io`, cmux-cloud-api `local_file`), so a file of any size up to that form's
    /// limit fits; its size is not known before the read, so every read takes it.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        struct Read: Decodable {
            var path: String?
            var size: Int64?
        }
        let file = try CloudTransferFile()
        defer { file.remove() }
        let read = try await machine("read", id, ["path": path, "local_path": file.url.path], wait: .seconds(120), as: Read.self)
        let data = try file.read()
        return CloudFileContents(path: read.path, dataBase64: data.base64EncodedString(), size: read.size ?? Int64(data.count))
    }

    /// Writes a guest file atomically. Past ``CloudTransferFile/inlineLimit`` the bytes go through a
    /// file of the app's (the path form of `cloud.machine.io`) instead of base64 in the call, which
    /// a protocol request (4 MiB) could not hold.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var args: [String: any Sendable] = ["path": path]
        if let mode { args["mode"] = mode }
        guard data.count > CloudTransferFile.inlineLimit else {
            args["data_base64"] = data.base64EncodedString()
            _ = try await machine("write", id, args, wait: .seconds(120))
            return
        }
        let file = try CloudTransferFile()
        defer { file.remove() }
        try file.write(data)
        args["local_path"] = file.url.path
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

/// One file of the path form of `cloud.machine.io` (cmux-cloud-api `local_file`): a new name in the
/// transfer folder `<NSTemporaryDirectory()>/cmux-cloud-transfer` (0700), the only folder the daemon
/// takes a file from or makes one in. Removed by its exact path after the call.
struct CloudTransferFile {
    /// The largest write that goes inline as base64: well under a protocol request's 4 MiB.
    static let inlineLimit = 1 << 20

    let url: URL

    /// A fresh name in the transfer folder, made 0700 if it is new; nothing is created at the name.
    /// (The daemon refuses a folder open to anyone else.)
    init() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-cloud-transfer", isDirectory: true)
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent(UUID().uuidString, isDirectory: false)
    }

    /// Writes `data` to a new 0600 file at the name (in a folder only this user may enter).
    func write(_ data: Data) throws {
        guard FileManager.checked.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CloudAPIError.transport("the transfer file could not be written")
        }
    }

    /// The bytes the daemon wrote at the name.
    func read() throws -> Data {
        try Data(blockingContentsOf: url)
    }

    func remove() {
        try? FileManager.checked.removeItem(at: url)
    }
}
