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
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, session: URLSession = CloudAPIClient.noStoreTransport,
                                      appVersion: String = "cmux-next") -> CloudAPIClient {
        CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, session: session, appVersion: appVersion)
    }

    /// `POST /api/vm/{id}/exec`: runs `command` in the machine's shell. The
    /// route caps `timeoutMs` at 15 minutes.
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await send("POST", "\(machinePath)/\(id)/exec", body: ["command": command, "timeoutMs": timeoutMs],
                       timeout: .milliseconds(timeoutMs) + .seconds(5), as: CloudExecResult.self)
    }

    /// Lists a guest directory through the authenticated backend wrapper.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: Decodable { var entries: [CloudFileEntry] }
        return try await send("GET", "\(machinePath)/\(id)/fs/dir?path=\(query(path))", as: List.self).entries
    }

    /// Reads a guest file. The backend encodes bytes as base64 for this JSON API.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await send("GET", "\(machinePath)/\(id)/fs/read?path=\(query(path))", timeout: .seconds(120), as: CloudFileContents.self)
    }

    /// Writes a guest file atomically through the backend wrapper.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var body: [String: any Sendable] = ["path": path, "dataBase64": data.base64EncodedString()]
        if let mode { body["mode"] = mode }
        _ = try await send("POST", "\(machinePath)/\(id)/fs/write", body: body, timeout: .seconds(120), as: Ignored.self)
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await send("POST", "\(machinePath)/\(id)/fs/mkdir", body: ["path": path], as: Ignored.self)
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await send("DELETE", "\(machinePath)/\(id)/fs/remove?path=\(query(path))", timeout: .seconds(120), as: Ignored.self)
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await send("GET", "\(machinePath)/\(id)/fs/stat?path=\(query(path))", as: CloudFileStat.self)
    }
}
