public import CMUXAuthCore
public import Foundation

/// A machine's exec and file routes: `/v1/cloud/machines/{id}/exec` and `/v1/cloud/machines/{id}/fs/...`
/// on a Worker machines client (``workerMachines(baseURL:accessToken:teamID:session:appVersion:machineIO:)``),
/// which sends the Stack access token and the cmux team in `x-cmux-team`, never the refresh token.
/// The sign-in client refuses them before any request (``requireWorker(code:)``).
extension CloudAPIClient {
    /// A Worker machine's (the Cloud app server link's) exec and file routes, under
    /// `/v1/cloud/machines/{id}/` on the cmux API Worker (`baseURL`:
    /// ``CloudConfiguration/ownerAPIBaseURL(environment:)``), as the person's Stack session
    /// (`accessToken`) in the cmux team `teamID` (`x-cmux-team`; the install token's team claim,
    /// the team the app link lists its machines in), like ``CloudOwnerAPIClient``. Never this Mac's
    /// install token: a Mac install has no execute grant, so the route refuses it with a 403
    /// (cmux-platform#89, backend cloud-machine-guest.ts). Only those routes serve there.
    /// `machineIO`: the bundled cmux, through which its exec and file routes (the daemon's `machine.io`,
    /// which reaches the machine's provider directly with a client session when it can and the same routes
    /// here otherwise) and its other daemon calls go. `installToken`: this Mac's install token, for the one
    /// call that takes an install, not a session (``listNetworks()``).
    public static func workerMachines(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                                      teamID: @escaping TeamID, session: URLSession = CloudAPIClient.noStoreTransport,
                                      appVersion: String = "cmux-next", machineIO: CloudMachineIO? = nil,
                                      installToken: (@Sendable () async throws -> String)? = nil,
                                      buildSpace: CMUXBuildSpaceState = .nightly) -> CloudAPIClient {
        var client = CloudAPIClient(baseURL: baseURL, tokens: { (try await accessToken(), "") }, teamID: teamID, session: session,
                                    appVersion: appVersion, buildSpace: buildSpace)
        client.machineIO = machineIO
        client.installToken = installToken
        return client
    }

    /// `POST /v1/cloud/machines/{id}/exec`: runs `command` in the machine's shell. The
    /// route caps `timeoutMs` at 5 minutes.
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await machine("exec", id, ["command": command, "timeout_ms": timeoutMs], timeout: .milliseconds(timeoutMs) + .seconds(5))
    }

    /// Starts the desktop closure on an existing running Cloud machine: the daemon's
    /// `machine.setup_desktop` (cmux-platform's `POST /v1/cloud/machines/{id}/desktop`). The platform route
    /// performs the root-owned capability repair; the app never asks the guest shell to invent it.
    public func setupDesktop(_ id: String) async throws {
        try requireWorker()
        // The route's own deadline is 30 s in Rust; this one only bounds a child that hangs.
        _ = try await cloudCall("machine.setup_desktop", ["id": id], timeout: .seconds(60))
    }

    /// Lists a guest directory through the authenticated backend wrapper.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: CloudServerModel {
            static var cloudModelKind: String { "file_entries" }
            var entries: [CloudFileEntry]
            init(from decoder: any Decoder) throws { entries = try [CloudFileEntry](from: decoder) }
        }
        return try await machine("dir", id, ["path": path], timeout: .seconds(20), as: List.self).entries
    }

    /// Reads a guest file. The backend encodes bytes as base64 for this JSON API.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await machine("read", id, ["path": path], timeout: .seconds(120))
    }

    /// Writes a guest file atomically through the backend wrapper.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var request: [String: any Sendable] = ["path": path, "data_base64": data.base64EncodedString()]
        if let mode { request["mode"] = mode }
        _ = try await machine("write", id, request, timeout: .seconds(120), as: Ignored.self)
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await machine("mkdir", id, ["path": path], timeout: .seconds(20), as: Ignored.self)
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await machine("remove", id, ["path": path], timeout: .seconds(120), as: Ignored.self)
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await machine("stat", id, ["path": path], timeout: .seconds(20))
    }

    /// One exec or file operation: refused on the sign-in client, else the daemon's `machine.io`
    /// (cmux-cloud-api `machine::worker`: the provider directly with a client session when it can, these
    /// routes otherwise; that choice and every fallback are Rust's), decoded exactly as the route's own
    /// answer. There is no Swift HTTP fallback: no bundled cmux is `transport` ("cmux is not available"),
    /// like every daemon call. A child that started and gave no answer is never sent again: the op may have run.
    private func machine<T: Decodable>(_ op: String, _ id: String, _ fields: [String: any Sendable], timeout: Duration,
                                       as type: T.Type = T.self) async throws -> T {
        try requireWorker()
        var args = fields
        args["op"] = op
        args["machine"] = id
        let body: Data
        do {
            // The child's own HTTP deadlines end first; this one only bounds a child that hangs.
            body = try await cloudCall("machine.io", args, timeout: timeout + .seconds(30))
        } catch CloudAPIError.timedOut("cloud.machine.io") {
            throw CloudAPIError.transport("cmux did not answer; the \(op) may have run")
        }
        if T.self == Ignored.self, let ignored = Ignored() as? T { return ignored }
        return try CloudMachineRules().answer(body, as: T.self, context: "\(machinePath)/\(id)/\(op == "exec" ? "exec" : "fs/\(op)")")
    }
}
