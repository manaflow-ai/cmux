public import Foundation

/// The cmux-next API Worker's routes that a person's own session calls directly, outside the op
/// path (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
/// machine of the app server link, a fork run, the person's hand-offs and their turns, the harness
/// login copy switch and the GitHub App status. Every request, check and answer's reading is
/// cmux-tui Rust's (`cmux cloud api`, `owner.*`; cmux-tui `cli/cloud_api/owner.rs`), which sets
/// only `Authorization`, `Content-Type`, `Content-Length` and `x-cmux-team` (the Worker's
/// invocation log records the URL and every other header, so nothing outside the body holds a
/// key), follows no redirect and retries nothing. This type reads the caller's token per call and
/// hands it to the bundled cmux on its stdin (``BundledCmux``).
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
    let cli: BundledCmux?

    public init(baseURL: URL, accessToken: @escaping AccessToken, teamID: @escaping TeamID, cli: BundledCmux?) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.teamID = teamID
        self.cli = cli
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/keyed-start`: restarts the machine's acpmux with
    /// this app's person key. `writeKey` writes the key line (`keyLineLength` bytes) into a stream
    /// from the caller's own zeroed buffer; the bytes go to the child's stdin after the request's
    /// line, never into a JSON value, and are zeroed here once sent. Answers the new daemon run
    /// (`personInstance`).
    public func acpmuxKeyedStart(_ machine: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, keyLineLength))
        buffer.initialize(repeating: 0, count: max(1, keyLineLength))
        defer {
            buffer.update(repeating: 0, count: max(1, keyLineLength))
            buffer.deallocate()
        }
        let stream = OutputStream(toBuffer: buffer, capacity: keyLineLength)
        stream.open()
        let wrote = writeKey(stream)
        stream.close()
        guard wrote else { throw CloudAPIError.transport("the key did not reach the request body") }
        var key = Data(bytes: buffer, count: keyLineLength)
        defer { key.resetBytes(in: 0..<key.count) }
        struct Started: Decodable { var personInstance: String }
        return try await call("owner.acpmux_keyed_start", ["machine": machine, "key_length": keyLineLength], tail: key,
                              timeout: .seconds(100), as: Started.self).personInstance
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/person-holds {nonce}`: what the machine's acpmux
    /// answers to `_acpmux/person_holds`. The caller checks the proof against its own key.
    public func acpmuxPersonHolds(_ machine: String, nonce: String) async throws -> (instance: String, proof: String) {
        struct Holds: Decodable { var instance: String; var proof: String }
        let holds = try await call("owner.acpmux_person_holds", ["machine": machine, "nonce": nonce], timeout: .seconds(40), as: Holds.self)
        return (holds.instance, holds.proof)
    }

    /// `POST /v1/workspaces/{workspace}/fork-runs`: snapshots the source machine now and creates
    /// one durable child for each requested harness. The platform intentionally has no checkpoint
    /// argument; transcript cut is performed by the child acpmux after it is ready.
    public func forkRun(workspace: String, clientKey: String, sourceMachine: String, session: String,
                        harnesses: [String]) async throws -> [ForkRunChild] {
        try await call("owner.fork_run", ["workspace": workspace, "clientKey": clientKey, "sourceMachine": sourceMachine,
                                          "session": session, "harnesses": harnesses],
                       timeout: .seconds(180), as: [ForkRunChild].self)
    }

    /// One `cmux cloud api` `owner.*` call as this person and team; its answer's body as JSON.
    func call(_ call: String, _ args: [String: any Sendable], tail: Data? = nil, timeout: Duration) async throws -> Data {
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        var request: [String: any Sendable] = ["call": call, "api": baseURL.absoluteString, "auth": "owner", "credential": access, "args": args]
        if let team = await teamID() { request["team"] = team }
        return try await CloudAPIAnswer.send(request, tail: tail, on: cli, timeout: timeout, baseURL: baseURL)
    }

    func call<T: Decodable>(_ name: String, _ args: [String: any Sendable], tail: Data? = nil, timeout: Duration,
                            as type: T.Type) async throws -> T {
        let data = try await call(name, args, tail: tail, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw CloudAPIError.decoding("\(name): \(error)") }
    }

    /// No cache, no cookies, and redirects refused: the Stack bearer never follows one. For the
    /// transport lanes' own sockets and requests (CloudRelayChat, CloudMachineStatePush, Hands).
    public static let transport: URLSession = {
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
