public import Foundation

/// The cmux-next API Worker's routes that a person's own session calls directly, outside the op
/// path (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
/// machine of the app server link, a fork run, the person's hand-offs and their turns
/// (CloudHandoffs.swift, CloudHandoffTurns.swift), the harness login copy switch and the GitHub App
/// status. Each but the keyed start (which streams the person key itself, see
/// ``acpmuxKeyedStart(_:keyLineLength:writeKey:)``) is the daemon's `cloud.owner.*` (``CloudDaemon``; cmux-cloud-api `owner.rs`), which
/// sets only `Authorization` and `x-cmux-team` (the Worker's invocation log records every other
/// header and the URL, so nothing else may hold a key), checks every id before it reaches a path,
/// follows no redirect and retries nothing.
public struct CloudOwnerAPIClient: Sendable {
    public struct ForkRunChild: Sendable, Equatable, Decodable {
        public var id: String
        public var harness: String
        public var state: String
        public var machineId: String?
        public var error: String?

        public init(id: String, harness: String, state: String, machineId: String?, error: String?) {
            self.id = id
            self.harness = harness
            self.state = state
            self.machineId = machineId
            self.error = error
        }
    }
    public typealias AccessToken = @Sendable () async throws -> String
    /// The cmux team (`team_…`) whose machine this is: the install token's team claim.
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let accessToken: AccessToken
    let teamID: TeamID
    let daemon: CloudDaemon

    public init(baseURL: URL, accessToken: @escaping AccessToken, teamID: @escaping TeamID, daemon: CloudDaemon) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.teamID = teamID
        self.daemon = daemon
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/keyed-start`: restarts the machine's acpmux with
    /// this app's person key. `writeKey` writes the key line (`keyLineLength` bytes) into the body
    /// stream from the caller's own zeroed buffer: no `Data` or `String` copy here, and a stream
    /// body is never resent. Answers the new daemon run (`personInstance`).
    ///
    /// The one call of this client that is not the daemon's: the person key never enters a JSON
    /// value, a protocol line or the daemon, whose generic params path keeps unwiped copies
    /// (review of #40104, F3). So it stays this streamed URLSession request, as before.
    public func acpmuxKeyedStart(_ machine: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: keyLineLength * 2, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw CloudAPIError.transport("no request body stream") }
        output.open()
        let wrote = writeKey(output)
        output.close()
        guard wrote else { throw CloudAPIError.transport("the key did not reach the request body") }
        struct Started: Decodable { var personInstance: String }
        return try await keyedStart(machine, body: input, length: keyLineLength, timeout: .seconds(100), as: Started.self).personInstance
    }

    /// The keyed start's request: the streamed body, and only these four headers: Authorization
    /// (the Worker's invocation log masks it), Content-Type, Content-Length and x-cmux-team. The log
    /// records every other header and the URL, so no other header, no query and no path part that
    /// could hold a key may ever be added here (cx-kvmz, hq-84). No cache, no cookies, no redirect.
    private func keyedStart<T: Decodable>(_ machine: String, body: InputStream, length: Int, timeout: Duration,
                                          as type: T.Type) async throws -> T {
        // The machine id is the only path part that varies; anything else is refused before a request.
        guard machine.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil else {
            throw CloudAPIError.transport("not a Cloud machine id")
        }
        let path = "/v1/cloud/machines/\(machine)/acpmux/keyed-start"
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = body
        // Ephemeral, for this request alone: no cache, no cookies, and redirects refused, so the
        // Stack bearer never follows one.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: CloudRefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            let prepared = request
            (data, response) = try await withDeadline(timeout, label: "POST \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        // The Worker's shape: {ok: true, value} or {ok: false, error: {code, message}}.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), object?["ok"] as? Bool == true, let value = object?["value"] else {
            let error = object?["error"] as? [String: Any]
            throw CloudAPIError.http(status: http.statusCode, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        guard let reply = try? JSONSerialization.data(withJSONObject: value) else { throw CloudAPIError.decoding("\(path): not JSON") }
        return try CloudMachineRules().answer(reply, as: T.self, context: path)
    }

    /// What the machine's acpmux answers to `_acpmux/person_holds` (`cloud.owner.acpmux_person_holds`).
    /// The caller checks the proof against its own key.
    public func acpmuxPersonHolds(_ machine: String, nonce: String) async throws -> (instance: String, proof: String) {
        struct Holds: Decodable { var instance: String; var proof: String }
        let data = try await call("owner.acpmux_person_holds", ["machine": machine, "nonce": nonce], wait: .seconds(40))
        let holds = try CloudMachineRules().answer(data, as: Holds.self, context: "acpmux person-holds")
        return (holds.instance, holds.proof)
    }

    /// Snapshots the source machine now and creates one durable child for each requested harness
    /// (`cloud.owner.fork_run`). The platform intentionally has no checkpoint argument; transcript
    /// cut is performed by the child acpmux after it is ready.
    public func forkRun(workspace: String, clientKey: String, sourceMachine: String, session: String,
                        harnesses: [String]) async throws -> [ForkRunChild] {
        let data = try await call("owner.fork_run", [
            "workspace": workspace, "clientKey": clientKey, "sourceMachine": sourceMachine, "session": session, "harnesses": harnesses,
        ], wait: .seconds(180))
        return try CloudMachineRules().answer(data, as: [ForkRunChild].self, context: "fork-runs")
    }

    /// One `cloud.<name>` call as the person (`owner`); its body as JSON.
    func call(_ name: String, _ args: [String: any Sendable] = [:], wait: Duration) async throws -> Data {
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        let route = CloudDaemon.Route(api: baseURL, auth: .owner, credential: access, team: await teamID())
        return try await daemon.call(name, args, as: route, wait: wait)
    }
}
