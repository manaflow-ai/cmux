public import Foundation

/// The cmux-next API Worker's routes that a person's own session calls directly, outside the op
/// path (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
/// machine of the app server link, a fork run, the person's hand-offs and their turns
/// (CloudHandoffs.swift, CloudHandoffTurns.swift), the harness login copy switch and the GitHub App
/// status. Each is the daemon's `cloud.owner.*` (``CloudDaemon``; cmux-cloud-api `owner.rs`), which
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

    /// Restarts the machine's acpmux with this app's person key (`cloud.owner.acpmux_keyed_start`).
    /// `writeKey` writes the key line (`keyLineLength` bytes) into a buffer this call wipes; the key
    /// goes only in the call's params, never in a `Data` or `String`. Answers the new daemon run
    /// (`personInstance`).
    public func acpmuxKeyedStart(_ machine: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        guard keyLineLength > 0 else { throw CloudAPIError.transport("the key did not reach the request body") }
        let key = try Self.read(keyLineLength, writeKey)
        struct Started: Decodable { var personInstance: String }
        let data = try await call("owner.acpmux_keyed_start", ["machine": machine, "key_length": keyLineLength], key: key,
                                  wait: .seconds(100))
        return try CloudMachineRules().answer(data, as: Started.self, context: "acpmux keyed-start").personInstance
    }

    /// The key line `writeKey` writes, in bytes that are wiped when the call ends.
    private static func read(_ length: Int, _ writeKey: (OutputStream) -> Bool) throws -> CloudSecretBytes {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: length * 2, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw CloudAPIError.transport("no request body stream") }
        output.open()
        let wrote = writeKey(output)
        output.close()
        guard wrote else { throw CloudAPIError.transport("the key did not reach the request body") }
        input.open()
        defer { input.close() }
        let key = CloudSecretBytes([UInt8](repeating: 0, count: length))
        let read = key.withMutableBytes { buffer in buffer.baseAddress.map { input.read($0, maxLength: length) } ?? -1 }
        guard read == length else { throw CloudAPIError.transport("the key did not reach the request body") }
        return key
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
    func call(_ name: String, _ args: [String: any Sendable] = [:], key: CloudSecretBytes? = nil, wait: Duration) async throws -> Data {
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        let route = CloudDaemon.Route(api: baseURL, auth: .owner, credential: access, team: await teamID())
        return try await daemon.call(name, args, as: route, key: key, wait: wait)
    }
}
