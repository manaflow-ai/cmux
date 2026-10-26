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
    private(set) var teamID: TeamID
    let session: URLSession
    let appVersion: String

    /// Requests that carry the account's bearer token: ephemeral, no URL
    /// cache, no cookies, so no answer (or the request headers stored with
    /// it) lands in `~/Library/Caches/<bundle id>/Cache.db`.
    public static let noStoreTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// The team requests go to now (`X-Cmux-Team-Id`).
    public func currentTeam() async -> String? { await teamID() }

    /// This client with its team fixed to `team`: every request of a create and its retries
    /// goes to the same team whatever the app switches to meanwhile.
    public func pinningTeam(_ team: String?) -> CloudAPIClient {
        var copy = self
        copy.teamID = { team }
        return copy
    }

    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID,
                session: URLSession = CloudAPIClient.noStoreTransport, appVersion: String = "cmux-next") {
        baseURL = configuration.apiBaseURL
        if case .localOnly = configuration.backend { backendIsLocalOnly = true } else { backendIsLocalOnly = false }
        self.tokens = tokens
        self.teamID = teamID
        self.session = session
        self.appVersion = appVersion
    }

    // MARK: Machines

    public func listMachines() async throws -> [CloudMachine] {
        try await listMachinesAndLimits().machines
    }

    /// `GET /api/vm`: the machines and the account's machine cap (`limits`;
    /// nil when the server sent none or sent one this client cannot read).
    public func listMachinesAndLimits() async throws -> (machines: [CloudMachine], limits: CloudMachineLimits?) {
        let list = try await send("GET", "/api/vm", as: CloudMachineList.self)
        return (list.vms, list.limits)
    }

    public func machine(_ id: String) async throws -> CloudMachine {
        try await send("GET", "/api/vm/\(id)", as: CloudMachine.self)
    }

    /// `POST /api/vm`. The server provisions for up to 600 s; the key makes a
    /// retry after a lost response return the same machine.
    /// `onSent` runs once the request goes on the wire (sign-in token and
    /// team resolved), so a caller can tell its request stage from the
    /// server's create.
    /// `idlePauseMinutes`: the machine's idle auto-pause from its create (0 is Off, a persistent
    /// machine); a server that does not store it answers without it (or with its default).
    public func createMachine(displayName: String?, memoryMb: Int? = nil, idlePauseMinutes: Int? = nil,
                              idempotencyKey: String = UUID().uuidString,
                              onSent: (@Sendable () async -> Void)? = nil) async throws -> CloudMachine {
        var body: [String: any Sendable] = [:]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        if let memoryMb { body["memoryMb"] = memoryMb }
        if let idlePauseMinutes {
            let value: any Sendable = idlePauseMinutes == 0 ? "off" : idlePauseMinutes
            body["idlePauseMinutes"] = value
        }
        return try await send("POST", "/api/vm", body: body, idempotencyKey: idempotencyKey, timeout: .seconds(620),
                              onSent: onSent, as: CloudMachine.self)
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

    /// `PUT /api/vm/{id}/idle-pause`: minutes of idle before the server
    /// pauses the machine, one of ``CloudMachine/idlePauseChoices``; 0 is Off.
    public func setIdlePause(_ id: String, minutes: Int) async throws {
        let value: any Sendable = minutes == 0 ? "off" : minutes
        _ = try await send("PUT", "/api/vm/\(id)/idle-pause", body: ["minutes": value], timeout: .seconds(30), as: Ignored.self)
    }

    public func attachEndpoint(_ id: String, deviceFingerprint: String? = nil) async throws -> CloudAttachEndpoint {
        var body: [String: any Sendable] = ["transport": "cmux-remote"]
        if let deviceFingerprint { body["deviceFingerprint"] = deviceFingerprint }
        return try await send("POST", "/api/vm/\(id)/attach-endpoint", body: body, timeout: .seconds(30),
                       as: CloudAttachEndpoint.self)
    }

    public func approveCmuxRemoteEnrollment(_ id: String, invitationID: String) async throws -> CloudEnrollmentApproval {
        try await send("POST", "/api/vm/\(id)/cmux-remote/approve", body: ["invitationId": invitationID],
                       timeout: .seconds(60), as: CloudEnrollmentApproval.self)
    }

    public func stats(_ id: String) async throws -> CloudMachineStats {
        try await send("GET", "/api/vm/\(id)/stats", as: CloudMachineStats.self)
    }

    /// `POST /api/vm/{id}/resize`: cpu 1-32, memory 4096-65536 MiB in whole GiB.
    public func resize(_ id: String, cpu: Int, memoryMb: Int) async throws {
        _ = try await send("POST", "/api/vm/\(id)/resize", body: ["cpu": cpu, "memoryMb": memoryMb], timeout: .seconds(120), as: Ignored.self)
    }

    public func snapshot(_ id: String, name: String?, idempotencyKey: String = UUID().uuidString) async throws -> CloudSnapshot {
        var body: [String: any Sendable] = [:]
        if let name { body["name"] = name }
        return try await send("POST", "/api/vm/\(id)/snapshot", body: body, idempotencyKey: idempotencyKey,
                              timeout: .seconds(300), as: CloudSnapshot.self)
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

    // MARK: Remote approvals (cx-psxg)

    /// `POST /api/vm/{id}/acpmux/keyed-start`: restarts the machine's acpmux with this app's
    /// person key. `writeKey` writes the key line (``keyLineLength`` bytes) into the request
    /// body from the caller's own zeroed buffer: the body is a stream, so this code makes no
    /// `Data` or `String` copy of the key, and URLSession cannot send it a second time (a stream
    /// body is never resent). Copies that nobody zeroes still exist in the bound stream pair's
    /// buffer and in URLSession's and TLS's buffers; they stay on this Mac, inside the trusted
    /// delivery boundary (#13742 D16 update 4). No Idempotency-Key and no retry: a request that
    /// did not answer is the person's to send again, with a new key. Answers the new daemon run
    /// (`personInstance`).
    public func acpmuxKeyedStart(_ id: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: keyLineLength * 2, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw CloudAPIError.transport("no request body stream") }
        output.open()
        let wrote = writeKey(output)
        output.close()
        guard wrote else { throw CloudAPIError.transport("the key did not reach the request body") }
        struct Started: Decodable { var personInstance: String }
        let started = try await send("POST", "/api/vm/\(id)/acpmux/keyed-start",
                                     bodyStream: (input, keyLineLength, "application/octet-stream"),
                                     timeout: .seconds(100), as: Started.self)
        return started.personInstance
    }

    /// `POST /api/vm/{id}/acpmux/person-holds {nonce}`: what the machine's acpmux answers to
    /// `_acpmux/person_holds`. The caller checks the proof against its own key.
    public func acpmuxPersonHolds(_ id: String, nonce: String) async throws -> (instance: String, proof: String) {
        struct Holds: Decodable { var instance: String; var proof: String }
        let holds = try await send("POST", "/api/vm/\(id)/acpmux/person-holds", body: ["nonce": nonce],
                                   timeout: .seconds(40), as: Holds.self)
        return (holds.instance, holds.proof)
    }

    // MARK: Files and SCP

    /// Mints a short-lived private SCP route. The public key is the only key
    /// material sent to the backend; the caller owns the corresponding secret.
    public func prepareSCP(_ id: String, publicKey: String) async throws -> CloudSCPEndpoint {
        let endpoint = try await send("POST", "/api/vm/\(id)/scp-endpoint", body: ["publicKey": publicKey],
                                      timeout: .seconds(100), as: CloudSCPEndpoint.self)
        guard endpoint.port == 22, endpoint.username == "cmux",
              endpoint.hostPublicKey.hasPrefix("ssh-ed25519 "),
              endpoint.expiresAtUnix > Int64(Date().timeIntervalSince1970) else {
            throw CloudAPIError.decoding("/api/vm/\(id)/scp-endpoint returned an unsafe endpoint")
        }
        return endpoint
    }

    /// Lists a guest directory through the authenticated backend wrapper.
    public func listFiles(_ id: String, path: String) async throws -> [CloudFileEntry] {
        struct List: Decodable { var entries: [CloudFileEntry] }
        return try await send("GET", "/api/vm/\(id)/fs/dir?path=\(query(path))", as: List.self).entries
    }

    /// Reads a guest file. The backend encodes bytes as base64 for this JSON API.
    public func readFile(_ id: String, path: String) async throws -> CloudFileContents {
        try await send("GET", "/api/vm/\(id)/fs/read?path=\(query(path))", timeout: .seconds(120), as: CloudFileContents.self)
    }

    /// Writes a guest file atomically through the backend wrapper.
    public func writeFile(_ id: String, path: String, data: Data, mode: Int? = nil) async throws {
        var body: [String: any Sendable] = ["path": path, "dataBase64": data.base64EncodedString()]
        if let mode { body["mode"] = mode }
        _ = try await send("POST", "/api/vm/\(id)/fs/write", body: body, timeout: .seconds(120), as: Ignored.self)
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        _ = try await send("POST", "/api/vm/\(id)/fs/mkdir", body: ["path": path], as: Ignored.self)
    }

    public func removeFile(_ id: String, path: String) async throws {
        _ = try await send("DELETE", "/api/vm/\(id)/fs/remove?path=\(query(path))", timeout: .seconds(120), as: Ignored.self)
    }

    public func statFile(_ id: String, path: String) async throws -> CloudFileStat {
        try await send("GET", "/api/vm/\(id)/fs/stat?path=\(query(path))", as: CloudFileStat.self)
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

    public func attachTunnelNetwork(deviceFingerprint: String, networkID: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await send("POST", "/api/vm/tunnel/network/attach", body: ["deviceFingerprint": deviceFingerprint, "networkId": networkID, "tunnelPurpose": tunnelPurpose], timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func detachTunnelNetwork(deviceFingerprint: String, networkID: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await send("POST", "/api/vm/tunnel/network/detach", body: ["deviceFingerprint": deviceFingerprint, "networkId": networkID, "tunnelPurpose": tunnelPurpose], timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func rotateTunnelKey(deviceFingerprint: String, publicKey: String, tunnelPurpose: String = "browser") async throws -> CloudTunnelNetworkMutation {
        try await send("POST", "/api/vm/tunnel/network/rotate-key", body: ["deviceFingerprint": deviceFingerprint, "clientPublicKey": publicKey, "tunnelPurpose": tunnelPurpose], timeout: .seconds(60), as: CloudTunnelNetworkMutation.self)
    }

    public func listFirewallRules(vpcID: String? = nil, vmID: String? = nil, tunnelID: String? = nil) async throws -> [CloudFirewallRule] {
        var parts: [String] = []
        if let vpcID { parts.append("vpcId=\(queryComponent(vpcID))") }
        if let vmID { parts.append("vmId=\(queryComponent(vmID))") }
        if let tunnelID { parts.append("tunnelId=\(queryComponent(tunnelID))") }
        struct List: Decodable { var rules: [CloudFirewallRule] }
        return try await send("GET", "/api/vm/firewall\(parts.isEmpty ? "" : "?\(parts.joined(separator: "&"))")", as: List.self).rules
    }

    public func listNetworks() async throws -> [CloudNetwork] {
        struct List: Decodable { var networks: [CloudNetwork] }
        return try await send("GET", "/api/vm/network", as: List.self).networks
    }

    public func getFirewallRule(_ ruleID: String) async throws -> CloudFirewallRule {
        try await send("GET", "/api/vm/firewall?ruleId=\(queryComponent(ruleID))", as: CloudFirewallRule.self)
    }

    public func createFirewallRule(source: CloudFirewallEndpoint, destination: CloudFirewallEndpoint, description: String? = nil) async throws -> CloudFirewallRule {
        var body: [String: any Sendable] = ["source": endpointBody(source), "destination": endpointBody(destination)]
        if let description { body["description"] = description }
        return try await send("POST", "/api/vm/firewall", body: body, timeout: .seconds(60), as: CloudFirewallRule.self)
    }

    private func endpointBody(_ endpoint: CloudFirewallEndpoint) -> [String: any Sendable] {
        var body: [String: any Sendable] = [:]
        if let value = endpoint.vmId { body["vmId"] = value }
        if let value = endpoint.vpcId { body["vpcId"] = value }
        if let value = endpoint.tunnelId { body["tunnelId"] = value }
        if let value = endpoint.cidr { body["cidr"] = value }
        if let value = endpoint.isPublic { body["public"] = value }
        if let value = endpoint.port { body["port"] = value }
        if let value = endpoint.protocolName { body["protocol"] = value }
        return body
    }

    public func deleteFirewallRule(_ ruleID: String) async throws {
        _ = try await send("DELETE", "/api/vm/firewall?ruleId=\(queryComponent(ruleID))", timeout: .seconds(60), as: Ignored.self)
    }

    // MARK: Domains and publications

    /// Lists custom domains owned by the signed-in account. Provider
    /// credentials and certificate material are never returned by this route.
    public func listDomains() async throws -> [CloudDomain] {
        struct List: Decodable { var domains: [CloudDomain] }
        return try await send("GET", "/api/vm/domains", as: List.self).domains
    }

    /// Lists redacted VM publications owned by the signed-in account.
    public func listPublications() async throws -> [CloudPublication] {
        struct List: Decodable { var publications: [CloudPublication] }
        return try await send("GET", "/api/vm/publications", as: List.self).publications
    }

    private func query(_ value: String) -> String {
        // Keep guest path separators readable, but never let a path inject a
        // second query item or fragment into the request URL.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func queryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(.init(charactersIn: "/?&=#"))) ?? value
    }

    // MARK: Runs

    /// `POST /api/runs` for a sandboxed Run (hq#3367): one task on a throwaway VM from a
    /// pinned image. The key makes a retry after a lost response return the same Run.
    /// Answers the server's JSON as is; the Run API's views already hold no secrets.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString) async throws -> Data {
        var body: [String: any Sendable] = ["environment": "sandboxed", "task": task]
        if let agent, !agent.isEmpty { body["agent"] = agent }
        if let image, !image.isEmpty { body["image"] = image }
        if let timeoutMs { body["timeoutMs"] = timeoutMs }
        return try await sendData("POST", "/api/runs", body: body, idempotencyKey: idempotencyKey)
    }

    /// `GET /api/runs/:id/wait`: the snapshot once the Run is terminal or after
    /// `timeoutMs` (the server caps it at 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await sendData("GET", "/api/runs/\(queryComponent(id))/wait?timeoutMs=\(wait)", timeout: .milliseconds(wait + 10_000))
    }

    /// `POST /api/runs/:id/cancel`; a sandbox's VM is destroyed before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await sendData("POST", "/api/runs/\(queryComponent(id))/cancel", timeout: .seconds(60))
    }

    // MARK: Transport

    struct Ignored: Decodable {}

    /// One request whose JSON body the caller reads itself.
    func sendData(_ method: String, _ path: String, body: [String: any Sendable]? = nil, idempotencyKey: String? = nil,
                  timeout: Duration = .seconds(20)) async throws -> Data {
        try await send(method, path, body: body, idempotencyKey: idempotencyKey, timeout: timeout, as: RawBody.self).data
    }

    /// The undecoded body; ``send(_:_:body:bodyStream:idempotencyKey:timeout:onSent:as:)`` hands it over as is.
    struct RawBody: Decodable {
        let data: Data
        init(data: Data) { self.data = data }
        init(from decoder: any Decoder) throws {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "RawBody is not decoded"))
        }
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: any Sendable]? = nil,
                            bodyStream: (stream: InputStream, length: Int, contentType: String)? = nil, idempotencyKey: String? = nil,
                            timeout: Duration = .seconds(20), onSent: (@Sendable () async -> Void)? = nil,
                            as type: T.Type) async throws -> T {
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
        } else if let bodyStream {
            request.setValue(bodyStream.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(bodyStream.length), forHTTPHeaderField: "Content-Length")
            request.httpBodyStream = bodyStream.stream
        }
        let data: Data
        let response: URLResponse
        await onSent?()
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
        if T.self == Ignored.self, let ignored = Ignored() as? T { return ignored }
        if T.self == RawBody.self, let raw = RawBody(data: data) as? T { return raw }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudAPIError.decoding("\(path): \(error)")
        }
    }
}
