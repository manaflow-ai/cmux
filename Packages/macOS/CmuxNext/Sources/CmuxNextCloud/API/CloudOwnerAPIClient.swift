public import Foundation
import CmuxNextDaemon

/// The cmux-next API Worker's routes that a person's own session calls directly, outside the op
/// path (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
/// machine of the app server link (`POST /v1/cloud/machines/{machine}/acpmux/...`), a fork run, and
/// the person's hand-offs (CloudHandoffs.swift). Every call but the keyed start is the daemon's
/// `cloud.owner.*` (``CloudAPICaller``; cmux-tui `cmux-cloud-api` `owner.rs`), which sends only
/// `Authorization` and `x-cmux-team`.
///
/// The keyed start alone is sent from here: the person key goes from the caller's own zeroed buffer
/// into the request body stream and never through the local daemon or a Cloud op. Its request sets
/// only `Authorization` (the Stack session, which the Worker's logs mask), `Content-Type`,
/// `Content-Length` and `x-cmux-team`; URLSession adds `User-Agent`, `Accept`, `Accept-Language`,
/// `Accept-Encoding` and `Host`, none of which holds a credential. No cache, no cookies, no redirect
/// is followed, and nothing is retried.
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
    let caller: CloudAPICaller
    let session: URLSession

    public init(baseURL: URL, accessToken: @escaping AccessToken, teamID: @escaping TeamID, caller: CloudAPICaller) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.teamID = teamID
        self.caller = caller
        session = Self.transport
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/keyed-start`: restarts the machine's acpmux with
    /// this app's person key. `writeKey` writes the key line (`keyLineLength` bytes) into the body
    /// stream from the caller's own zeroed buffer: no `Data` or `String` copy here, and a stream
    /// body is never resent. Answers the new
    /// daemon run (`personInstance`).
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
        return try await post(machine, "keyed-start", body: input, length: keyLineLength, timeout: .seconds(100),
                              as: Started.self).personInstance
    }

    /// `owner.acpmux_person_holds {machine, nonce}`: what the machine's acpmux answers to
    /// `_acpmux/person_holds`. The caller checks the proof against its own key.
    public func acpmuxPersonHolds(_ machine: String, nonce: String) async throws -> (instance: String, proof: String) {
        struct Holds: Decodable { var instance: String; var proof: String }
        let holds = try await call("owner.acpmux_person_holds", ["machine": .string(machine), "nonce": .string(nonce)],
                                   timeout: .seconds(40), as: Holds.self)
        return (holds.instance, holds.proof)
    }

    /// `owner.fork_run` (`POST /v1/workspaces/{workspace}/fork-runs`): snapshots the source machine
    /// now and creates one durable child for each requested harness. The platform intentionally has
    /// no checkpoint argument; transcript cut is performed by the child acpmux after it is ready.
    public func forkRun(workspace: String, clientKey: String, sourceMachine: String, session: String,
                        harnesses: [String]) async throws -> [ForkRunChild] {
        try await call("owner.fork_run", [
            "workspace": .string(workspace), "clientKey": .string(clientKey), "sourceMachine": .string(sourceMachine),
            "session": .string(session), "harnesses": .array(harnesses.map(JSONValue.string)),
        ], timeout: .seconds(180), as: [ForkRunChild].self)
    }

    /// One `cloud.owner.*` call as the person's session, read as `T`.
    func call<T: Decodable>(_ name: String, _ args: [String: JSONValue], timeout: Duration, as type: T.Type) async throws -> T {
        try await caller.call(name, as: try await credentials(), args: args, timeout: timeout, decoding: T.self)
    }

    func credentials() async throws -> CloudAPICaller.Credentials {
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        return CloudAPICaller.Credentials(auth: "owner", api: baseURL, access: access, team: await teamID())
    }

    func post<T: Decodable>(_ machine: String, _ action: String, body: InputStream, length: Int, timeout: Duration,
                            as type: T.Type) async throws -> T {
        // The machine id is the only path part that varies; anything else is refused before a request.
        guard machine.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil else {
            throw CloudAPIError.transport("not a Cloud machine id")
        }
        let path = "/v1/cloud/machines/\(machine)/acpmux/\(action)"
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = "POST"
        // RULE (cx-kvmz, hq-84): this client sets only these four headers: Authorization (the
        // Worker's invocation log masks it), Content-Type, Content-Length and x-cmux-team. The log
        // records every other header and the URL, so no other header, no query and no path part
        // that could hold a key may ever be added here.
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = body
        let data: Data
        let response: URLResponse
        do {
            let session = session, prepared = request
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

    /// No cache, no cookies, and redirects refused: the Stack bearer never follows one.
    static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
