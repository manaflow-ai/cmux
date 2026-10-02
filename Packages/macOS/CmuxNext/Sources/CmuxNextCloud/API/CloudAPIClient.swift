public import Foundation

/// The `/api/vm` REST client (web/app/api/vm). Native auth is
/// `Authorization: Bearer <access>` plus `X-Stack-Refresh-Token`; the team
/// rides `X-Cmux-Team-Id`. Every call has a deadline; a miss is
/// `CloudAPIError.timedOut`, never a hang. Tokens come from the caller per
/// request and are never stored here.
public struct CloudAPIClient: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let backendIsLocalOnly: Bool
    let tokens: Tokens
    let teamID: TeamID
    let session: URLSession
    let appVersion: String

    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID,
                session: URLSession = .shared, appVersion: String = "cmux-next") {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.session = session
        self.appVersion = appVersion
    }

    // MARK: Machines

    public func listMachines() async throws -> [CloudMachine] {
        struct List: Decodable { var vms: [CloudMachine] }
        return try await send("GET", "/api/vm", as: List.self).vms
    }

    public func machine(_ id: String) async throws -> CloudMachine {
        try await send("GET", "/api/vm/\(id)", as: CloudMachine.self)
    }

    /// `POST /api/vm`. The server provisions for up to 600 s; the key makes a
    /// retry after a lost response return the same machine.
    public func createMachine(displayName: String?, memoryMb: Int? = nil, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        var body: [String: any Sendable] = [:]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        if let memoryMb { body["memoryMb"] = memoryMb }
        return try await send("POST", "/api/vm", body: body, idempotencyKey: idempotencyKey, timeout: .seconds(620), as: CloudMachine.self)
    }

    public func renameMachine(_ id: String, to name: String?) async throws {
        let body: [String: any Sendable] = ["displayName": name ?? NSNull()]
        _ = try await send("PATCH", "/api/vm/\(id)", body: body, as: Ignored.self)
    }

    public func deleteMachine(_ id: String) async throws {
        _ = try await send("DELETE", "/api/vm/\(id)", timeout: .seconds(120), as: Ignored.self)
    }

    /// Parks the machine while preserving its disk and session.
    public func pauseMachine(_ id: String) async throws {
        _ = try await send("POST", "/api/vm/\(id)/pause", timeout: .seconds(960), as: Ignored.self)
    }

    /// Resume can wait up to the route's 16-minute provider readiness budget.
    public func resumeMachine(_ id: String) async throws {
        _ = try await send("POST", "/api/vm/\(id)/resume", timeout: .seconds(960), as: Ignored.self)
    }

    public func attachEndpoint(_ id: String) async throws -> CloudAttachEndpoint {
        try await send("POST", "/api/vm/\(id)/attach-endpoint", body: ["transport": "cmux-remote"], timeout: .seconds(30),
                       as: CloudAttachEndpoint.self)
    }

    public func stats(_ id: String) async throws -> CloudMachineStats {
        try await send("GET", "/api/vm/\(id)/stats", as: CloudMachineStats.self)
    }

    /// `POST /api/vm/{id}/resize`: cpu 1-32, memory 4096-65536 MiB in whole GiB.
    public func resize(_ id: String, cpu: Int, memoryMb: Int) async throws {
        _ = try await send("POST", "/api/vm/\(id)/resize", body: ["cpu": cpu, "memoryMb": memoryMb], timeout: .seconds(120), as: Ignored.self)
    }

    public func snapshot(_ id: String, name: String?) async throws -> CloudSnapshot {
        var body: [String: any Sendable] = [:]
        if let name { body["name"] = name }
        return try await send("POST", "/api/vm/\(id)/snapshot", body: body, timeout: .seconds(300), as: CloudSnapshot.self)
    }

    public func snapshots(_ id: String) async throws -> [CloudSnapshot] {
        struct List: Decodable { var snapshots: [CloudSnapshot] }
        return try await send("GET", "/api/vm/\(id)/snapshots", as: List.self).snapshots
    }

    /// Deletes a snapshot scoped to the machine that owns it.
    public func deleteSnapshot(_ id: String, snapshotID: String) async throws {
        _ = try await send("DELETE", "/api/vm/\(id)/snapshots/\(snapshotID)", timeout: .seconds(960), as: Ignored.self)
    }

    public func restore(snapshotID: String, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        try await send("POST", "/api/vm/restore", body: ["snapshotId": snapshotID], idempotencyKey: idempotencyKey,
                       timeout: .seconds(620), as: CloudMachine.self)
    }

    public func fork(_ id: String, name: String?, idempotencyKey: String = UUID().uuidString) async throws -> CloudMachine {
        var body: [String: any Sendable] = [:]
        if let name { body["name"] = name }
        return try await send("POST", "/api/vm/\(id)/fork", body: body, idempotencyKey: idempotencyKey, timeout: .seconds(620),
                              as: CloudMachine.self)
    }

    public func openPort(_ id: String, port: Int) async throws -> CloudPortLink {
        try await send("POST", "/api/vm/\(id)/open-port", body: ["port": port], timeout: .seconds(30), as: CloudPortLink.self)
    }

    /// `POST /api/vm/{id}/exec`: runs `command` in the machine's shell. The
    /// route caps `timeoutMs` at 15 minutes.
    public func exec(_ id: String, command: String, timeoutMs: Int = 30_000) async throws -> CloudExecResult {
        try await send("POST", "/api/vm/\(id)/exec", body: ["command": command, "timeoutMs": timeoutMs],
                       timeout: .milliseconds(timeoutMs) + .seconds(5), as: CloudExecResult.self)
    }

    // MARK: Tunnel

    /// `POST /api/vm/tunnel`: enrolls this Mac's WireGuard public key. The
    /// private key never leaves the Mac.
    public func enrollTunnel(_ request: CloudTunnelEnrollment.Request) async throws -> CloudTunnelEnrollment {
        try await send("POST", "/api/vm/tunnel", body: request.body, timeout: .seconds(60), as: CloudTunnelEnrollment.self)
    }

    /// `DELETE /api/vm/tunnel?deviceId=…`: revokes this Mac's peer.
    public func revokeTunnel(deviceID: String) async throws {
        _ = try await send("DELETE", "/api/vm/tunnel?deviceId=\(deviceID)", as: Ignored.self)
    }

    // MARK: Transport

    struct Ignored: Decodable {}

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: any Sendable]? = nil, idempotencyKey: String? = nil,
                            timeout: Duration = .seconds(20), as type: T.Type) async throws -> T {
        let (access, refresh): (String, String)
        do { (access, refresh) = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(refresh, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("cmux-mac", forHTTPHeaderField: "X-Cmux-Client")
        request.setValue(appVersion, forHTTPHeaderField: "X-Cmux-App-Version")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "X-Cmux-Team-Id") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            let session = session, prepared = request
            (data, response) = try await withDeadline(timeout, label: "\(method) \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where backendIsLocalOnly && error.code == .cannotConnectToHost {
            throw CloudAPIError.noBackend(baseURL)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudAPIError.from(status: http.statusCode, data: data, headerCode: http.value(forHTTPHeaderField: "x-cmux-vm-error"))
        }
        if T.self == Ignored.self { return Ignored() as! T } // swiftlint:disable:this force_cast
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudAPIError.decoding("\(path): \(error)")
        }
    }
}
