import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// A machine's exec and file calls on a Worker machines client
/// (``workerMachines(baseURL:accessToken:teamID:daemon:work:appVersion:machineIO:installToken:)``): the
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
    /// takes an install, not a session (``listNetworks()``). `work`: the app's blocking-work lanes;
    /// a transfer file's disk work runs on its files lane, never on Swift's cooperative pool.
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, daemon: CloudDaemon, work: BackgroundWork, appVersion: String = "cmux-next",
                                      machineIO: CloudMachineIO? = nil,
                                      installToken: (@Sendable () async throws -> String)? = nil) -> CloudAPIClient {
        var client = CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, daemon: daemon,
                                    appVersion: appVersion)
        client.machineIO = machineIO
        client.installToken = installToken
        client.work = work
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
        let work = try fileWork()
        let file = try await CloudTransferFile.make(on: work)
        do {
            let read = try await machine("read", id, ["path": path, "local_path": file.url.path], wait: .seconds(120),
                                         ended: file.callEnded, as: Read.self)
            let (encoded, count) = try await file.base64(on: work)
            await file.done(on: work)
            return CloudFileContents(path: read.path, dataBase64: encoded, size: read.size ?? Int64(count))
        } catch {
            await file.done(on: work)
            throw error
        }
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
        let work = try fileWork()
        let file = try await CloudTransferFile.make(on: work)
        do {
            try await file.write(data, on: work)
        } catch {
            // No call was made: the call's hold goes too.
            file.callEnded()
            await file.done(on: work)
            throw error
        }
        do {
            args["local_path"] = file.url.path
            _ = try await machine("write", id, args, wait: .seconds(120), ended: file.callEnded)
        } catch {
            await file.done(on: work)
            throw error
        }
        await file.done(on: work)
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

    /// The lanes a transfer file's disk work runs on (a Worker machines client's own).
    private func fileWork() throws -> BackgroundWork {
        try requireWorker()
        guard let work else { throw CloudAPIError.transport("machine file calls are a Worker machines client's") }
        return work
    }

    /// One exec or file operation (`cloud.machine.io` with `op`); refused on the sign-in client.
    /// `ended` runs once the call has really ended (``CloudDaemon/Send``).
    private func machine(_ op: String, _ id: String, _ fields: [String: any Sendable], wait: Duration,
                         ended: (@Sendable () -> Void)? = nil) async throws -> Data {
        do { try requireWorker() } catch {
            ended?()
            throw error
        }
        var args = fields
        args["op"] = op
        args["machine"] = id
        return try await call("machine.io", args, wait: wait + .seconds(30), ended: ended)
    }

    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: any Sendable], wait: Duration,
                                       ended: (@Sendable () -> Void)? = nil, as type: T.Type) async throws -> T {
        let path = "/v1/cloud/machines/\(id)/\(op == "exec" ? "exec" : "fs/\(op)")"
        return try CloudMachineRules().answer(try await machine(op, id, fields, wait: wait, ended: ended), as: T.self, context: path)
    }
}

/// One file of the path form of `cloud.machine.io` (cmux-cloud-api `local_file`): a new name in the
/// transfer folder `<per-user temp dir>/cmux-cloud-transfer` (0700), the only folder the daemon takes
/// a file from or makes one in. The per-user temp dir is `confstr(_CS_DARWIN_USER_TEMP_DIR)`, as the
/// daemon reads it, never `NSTemporaryDirectory()` (which follows a `TMPDIR` override).
///
/// The file is removed by its exact path once both the caller is done with it and the daemon call
/// has really ended (``callEnded``): a cancelled caller is done at once, while the call may still
/// create or read the file, so neither alone removes it.
final class CloudTransferFile: Sendable {
    /// The largest write that goes inline as base64: well under a protocol request's 4 MiB.
    static let inlineLimit = 1 << 20

    let url: URL
    /// The parties still holding the file: the caller and the call.
    private let holders = Mutex(2)

    private init(url: URL) { self.url = url }

    /// The transfer folder, as the daemon resolves it.
    static func folder() throws -> URL {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 1, length <= buffer.count else { throw CloudAPIError.transport("no per-user temp dir") }
        let temp = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        let temp = NSTemporaryDirectory()
        #endif
        return URL(fileURLWithPath: temp, isDirectory: true).appendingPathComponent("cmux-cloud-transfer", isDirectory: true)
    }

    /// A fresh name in the transfer folder, made 0700 if it is new; nothing is created at the name.
    /// (The daemon refuses a folder open to anyone else.) Every disk step here runs on `work`'s files
    /// lane (review of #40104 at bac760b8, F2): never on the caller's actor (a Cloud action handler
    /// calls these on the main actor) nor on Swift's cooperative pool, which large transfers would hold.
    static func make(on work: BackgroundWork) async throws -> CloudTransferFile {
        let folder = try Self.folder()
        try await work.run(.userVisible, mayBlock: .files) {
            try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return CloudTransferFile(url: folder.appendingPathComponent(UUID().uuidString, isDirectory: false))
    }

    /// Writes `data` to a new 0600 file at the name (in a folder only this user may enter).
    func write(_ data: Data, on work: BackgroundWork) async throws {
        let url = url
        let written = try await work.run(.userVisible, mayBlock: .files) {
            FileManager.checked.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        guard written else { throw CloudAPIError.transport("the transfer file could not be written") }
    }

    /// The bytes the daemon wrote at the name, as base64, and how many there are.
    func base64(on work: BackgroundWork) async throws -> (String, Int) {
        let url = url
        return try await work.run(.userVisible, mayBlock: .files) {
            let data = try Data(blockingContentsOf: url)
            return (data.base64EncodedString(), data.count)
        }
    }

    /// The call's end (``CloudDaemon/Send``'s `ended`, on the call's own thread).
    var callEnded: @Sendable () -> Void { { [self] in release() } }

    /// The caller is done with the file (answered, failed or cancelled): let go on the files lane,
    /// which runs it even at quit; a caller cancelled before it starts lets go here (one unlink).
    func done(on work: BackgroundWork) async {
        do {
            try await work.run(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { [self] in release() }
        } catch {
            release()
        }
    }

    /// Removes the file when the last holder lets it go.
    private func release() {
        let last = holders.withLock { count in
            count -= 1
            return count == 0
        }
        if last { try? FileManager.checked.removeItem(at: url) }
    }
}
