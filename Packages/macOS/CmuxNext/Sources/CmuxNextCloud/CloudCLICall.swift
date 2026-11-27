public import CMUXAuthCore
public import CmuxNextDaemon
public import Foundation
import CmuxNextCompat

/// One stdin-JSON call of the bundled `cmux` (`cmux cloud <subcommand>`, cmux-tui `cli/cloud_*.rs`):
/// the request goes on the child's stdin (a credential never goes in argv), the answer is its last
/// stdout line. Cloud logic lives in that Rust; Swift only runs it. Every one-shot Cloud subcommand
/// the app runs goes through this one runner.
public struct CloudCLICall: Sendable {
    /// The app's bundled `cmux` (or `CMUX_NEXT_TUI_BIN`).
    public let cli: BundledExecutable

    public init(cli: BundledExecutable) { self.cli = cli }

    /// Why a call gave no answer line: no `cmux` in this build, or a child that failed, timed out or printed none.
    public struct NoAnswer: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    /// Runs `cmux <arguments>` with `stdin`; the last non-empty stdout line.
    public func run(_ arguments: [String], stdin: Data, timeout: Duration) async throws -> Data {
        guard let binary = await cli.resolve() else { throw NoAnswer(description: "this build has no cmux") }
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, stdin: stdin,
                                                 timeout: timeout, clock: ContinuousClock())
        guard let line = result.stdout.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else {
            throw NoAnswer(description: "cmux \(arguments.joined(separator: " ")) answered nothing (exit \(result.status))")
        }
        return Data(line)
    }

    /// `cmux cloud automation-relay` as the signed-in person of `auth`: what `cmux automation
    /// --target cloud`, the Automations page and the Chief's automation tool call (the app's
    /// `cloud.automation`). The forward takes `{op, params?, idempotency_key?}` as JSON bytes and
    /// answers `{ok: true, value}` or `{ok: false, error: {code, message, details?}}`; the rules are
    /// cmux-tui's `cmux_cloud_wire::automation`. The token is read per call, never stored.
    @MainActor
    public func automationRelay(signedIn auth: CloudAuth) -> @Sendable (Data) async -> Data {
        let api = auth.configuration.ownerAPIBaseURL().absoluteString
        let token: @Sendable () async -> Result<String?, any Error> = { @MainActor [weak auth] in
            guard let auth, auth.isSignedIn else { return .success(nil) }
            do { return .success(try await auth.tokens().access) } catch { return .failure(error) }
        }
        return { [self] request in
            let credential: String?
            switch await token() {
            case let .success(found): credential = found
            case let .failure(error): return Self.unreachable(String(describing: error))
            }
            guard let stdin = await Self.relayEnvelope(api: api, credential: credential, request: request) else {
                return Self.unreachable("the request is not JSON")
            }
            do {
                return try await run(["cloud", "automation-relay"], stdin: stdin, timeout: .seconds(25))
            } catch {
                return Self.unreachable(String(describing: error))
            }
        }
    }

    /// `cmux cloud apps-relay` as the signed-in person of `auth`: the app's `cloud.apps`, what `cmux app
    /// ls` and `cmux app versions` call off a Cloud machine (RFD 0003). The forward takes `{op: "list"}` or
    /// `{op: "get", slug}` as JSON bytes and answers `{ok: true, value}` or `{ok: false, error}`; the
    /// rules (two reads, nothing else) are cmux-tui's `cmux_apps::account`. The token is read per call,
    /// never stored, and goes on stdin.
    @MainActor
    public func appsRelay(signedIn auth: CloudAuth) -> @Sendable (Data) async -> Data {
        let api = auth.configuration.relayAPIBaseURL().absoluteString
        let session: @Sendable () async -> Result<(String, String?)?, any Error> = { @MainActor [weak auth] in
            guard let auth, auth.isSignedIn else { return .success(nil) }
            do { return .success((try await auth.tokens().access, auth.teamID)) } catch { return .failure(error) }
        }
        return { [self] request in
            let found: (String, String?)?
            switch await session() {
            case let .success(value): found = value
            case let .failure(error): return Self.unreachable(String(describing: error))
            }
            guard let stdin = await Self.relayEnvelope(api: api, credential: found?.0, team: found?.1, request: request) else {
                return Self.unreachable("the request is not JSON")
            }
            do {
                return try await run(["cloud", "apps-relay"], stdin: stdin, timeout: .seconds(25))
            } catch {
                return Self.unreachable(String(describing: error))
            }
        }
    }

    /// The automation relay's stdin: the caller's request (any size) parsed and re-encoded inside the
    /// envelope, so its bytes can never add a field of their own. Off the main actor.
    /// `team`, when set, scopes the call to that team (the apps relay's `team` field).
    @concurrent private static func relayEnvelope(api: String, credential: String?, team: String? = nil, request: Data) async -> Data? {
        let parsed = (try? JSONSerialization.jsonObject(with: request, options: .fragmentsAllowed)) ?? NSNull()
        var envelope: [String: Any] = ["api": api, "credential": credential.map { $0 as Any } ?? NSNull(), "request": parsed]
        if let team { envelope["team"] = team }
        return try? JSONSerialization.data(withJSONObject: envelope)
    }

    /// One `cmux cloud api` answer line (the child's whole last stdout line), decoded off the main actor.
    @concurrent private static func answer<Answer: Decodable & Sendable>(_ type: Answer.Type, from line: Data) async -> Answer? {
        try? JSONDecoder().decode(type, from: line)
    }

    /// `cmux cloud api` (cmux-tui `cli/cloud_api.rs`, the cmux-cloud-api crate behind the daemon's
    /// `cloud.<call>` ops) on this Mac's daemon at `socket`, as the signed-in person of `auth` on the platform origin, worker auth. The
    /// answer line as is: `{"ok": true, "body": B}` or `{"ok": false, "error": {"kind", "code", "message", …}}`.
    /// The token is read per call and goes on stdin, never in argv. `tail`: bytes the call takes after the request's
    /// first newline (`cloud_api.rs`'s secret tail, never in argv or the request JSON).
    @MainActor
    func cloudAPI(_ call: String, args: [String: any Sendable], signedIn auth: CloudAuth, socket: String,
                  timeout: Duration = .seconds(60), tail: Data? = nil) async -> Data {
        let failed = { (kind: String, message: String) in
            // main-actor-ok: a two-key failure object with a kind and one message.
            (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["kind": kind, "message": message]])) ?? Data()
        }
        guard auth.isSignedIn, let credential = try? await auth.tokens().access else { return failed("not_signed_in", "") }
        var request: [String: Any] = ["call": call, "api": auth.configuration.relayAPIBaseURL().absoluteString, "auth": "worker",
                                      "credential": credential, "args": args]
        if let team = auth.teamID { request["team"] = team }
        // main-actor-ok: a call name, the API origin, one token and the caller's few scalar args (ids, names); the tail is appended as bytes.
        guard var stdin = try? JSONSerialization.data(withJSONObject: request) else { return failed("transport", "the request is not JSON") }
        if let tail { stdin.append(0x0A); stdin.append(tail) }
        do {
            return try await run(["--socket", socket, "cloud", "api"], stdin: stdin, timeout: timeout)
        } catch {
            return failed("transport", String(describing: error))
        }
    }

    /// Share with Me on a teammate's Cloud machine's refused chat start (the agent pane's
    /// `machine.share.self`): cmux-platform's `PUT /v1/machines/{id}/chat-grants/{user}` for the
    /// signed-in person, sent by the cmux-cloud-api crate (`machine.share_chat` with `me`) on this Mac's daemon at `socket`. Nil once
    /// the person may start chats there; else the platform's refusal code (`machine.creator_or_admin`,
    /// `machine.private`, …) or the call's failure kind (`not_signed_in`, `timed_out`, `transport`, …), and its message.
    @MainActor
    public func shareChatWithMe(machine: String, signedIn auth: CloudAuth, socket: String?) async -> (code: String, message: String)? {
        guard let user = auth.platformUserID else { return ("not_signed_in", "") }
        guard let socket else { return ("transport", "") }
        struct Answer: Decodable, Sendable {
            struct Failure: Decodable, Sendable { var kind: String?; var code: String?; var message: String? }
            var ok: Bool
            var error: Failure?
        }
        let line = await cloudAPI("machine.share_chat", args: ["machine": machine, "user": user, "me": true], signedIn: auth, socket: socket)
        guard let answer = await Self.answer(Answer.self, from: line) else { return ("transport", "") }
        return answer.ok ? nil : (answer.error?.code ?? answer.error?.kind ?? "transport", answer.error?.message ?? "")
    }

    /// A Chief on its own Cloud machine (New Chief's "On its own Cloud machine"): the cmux-cloud-api crate's
    /// `machine.chief_start` on this Mac's daemon at `socket` makes the machine sized for a Chief, pairs it, places the
    /// Chief on it, keeps it from idle-pausing and starts its host. `key` names this one start: the same key again
    /// finishes a half-done start and never makes a second machine. The Chief's main conversation, or the refusal
    /// code (`chief.host_missing`, `chief.pair_failed`, …) or failure kind, and its message. `turnEnv`: the owner's Claude
    /// connection's env, sent as the call's stdin tail (`{"env": …}`); the Rust start picks the Claude variable from it and
    /// leaves it on the machine for the Chief's turns (cmux-cloud-api `chief_turn.rs`). Nil: the start as before.
    @MainActor
    public func startChiefOnMachine(key: String, name: String, signedIn auth: CloudAuth,
                                    socket: String?, turnEnv: [String: String]? = nil) async -> Result<String, CloudCallRefusal> {
        guard let socket else { return .failure(CloudCallRefusal(code: "transport", message: "")) }
        struct Answer: Decodable, Sendable {
            struct Body: Decodable, Sendable { var conversation: String? }
            struct Failure: Decodable, Sendable { var kind: String?; var code: String?; var message: String? }
            var ok: Bool
            var body: Body?
            var error: Failure?
        }
        // The Rust call bounds itself (machine boot, pairing, the host); this outlasts it.
        // main-actor-ok: the owner's Claude connection env, a few variables.
        let tail = turnEnv.flatMap { try? JSONSerialization.data(withJSONObject: ["env": $0]) }
        let line = await cloudAPI("machine.chief_start", args: ["key": key, "name": name], signedIn: auth, socket: socket,
                                  timeout: .seconds(1_560), tail: tail)
        guard let answer = await Self.answer(Answer.self, from: line) else {
            return .failure(CloudCallRefusal(code: "transport", message: ""))
        }
        if answer.ok, let conversation = answer.body?.conversation { return .success(conversation) }
        return .failure(CloudCallRefusal(code: answer.error?.code ?? answer.error?.kind ?? "transport",
                                         message: answer.error?.message ?? ""))
    }

    /// `cmux cloud auth-handoff-relay` (cmux-tui `cli/cloud_auth_handoff_relay.rs`) for `auth.handoff.mint` and
    /// `auth.handoff.redeem` (`cmux auth handoff`): `op` is `mint` or `redeem`, the request its params as JSON
    /// bytes, the answer `{ok: true, value}` or `{ok: false, error: {code, message}}`. The two cmux-api requests and
    /// their rules are that Rust's. This hands it the signed-in human Stack session for a mint (read per call, on
    /// stdin, never argv) and the account signed in now for a redeem, signs in with the session a redeem answers
    /// through the browser sign-in's own completion, and answers only the reply, never a token. A redeem whose
    /// account changed while it ran signs nothing in.
    @MainActor
    public func authHandoffRelay(signedIn auth: CloudAuth) -> @Sendable (String, Data) async -> Data {
        let api = auth.configuration.ownerAPIBaseURL().absoluteString
        let account: @Sendable (Bool) async -> (credential: String?, user: String?) = { @MainActor [weak auth] mint in
            guard let auth else { return (nil, nil) }
            if mint {
                guard await auth.restoredAccessToken() != nil, let access = try? await auth.tokens().access else { return (nil, nil) }
                return (access, nil)
            }
            await auth.awaitRestored()
            return (nil, auth.isSignedIn ? auth.user?.id : nil)
        }
        let signIn: @Sendable (String?, String, String) async -> Bool = { @MainActor [weak auth] before, access, refresh in
            guard let auth, (auth.isSignedIn ? auth.user?.id : nil) == before else { return false }
            return await auth.browserSignIn.completeHandoff(accessToken: access, refreshToken: refresh)
        }
        let unchanged: @Sendable (String?) async -> Bool = { @MainActor [weak auth] before in
            guard let auth else { return false }
            return (auth.isSignedIn ? auth.user?.id : nil) == before
        }
        return { [self] op, request in
            let mint = op == "mint"
            let (credential, before) = await account(mint)
            if mint, credential == nil { return Self.handoffRefusal("not_signed_in", "Sign in to cmux on this Mac first.") }
            guard let stdin = Self.handoffEnvelope(api: api, credential: credential, op: op, request: request, expectedUser: before),
                  let line = try? await run(["cloud", "auth-handoff-relay"], stdin: stdin, timeout: .seconds(23)) else {
                return Self.handoffUnavailable
            }
            guard !mint, let redeemed = Self.handoffRedeemed(line) else { return line }
            if let session = redeemed.session {
                guard await signIn(before, session.access, session.refresh) else { return Self.handoffUnavailable }
            } else if await !unchanged(before) {
                return Self.handoffUnavailable
            }
            return redeemed.reply
        }
    }

    /// The relay's stdin: the origin, the credential and the request (`device` and `code` from the params, `op` and
    /// `expected_user` this app's own).
    nonisolated private static func handoffEnvelope(api: String, credential: String?, op: String, request: Data, expectedUser: String?) -> Data? {
        let params = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
        var body = params.filter { $0.key == "device" || $0.key == "code" }
        body["op"] = op
        if let expectedUser { body["expected_user"] = expectedUser }
        let envelope: [String: Any] = ["api": api, "credential": credential.map { $0 as Any } ?? NSNull(), "request": body]
        return try? JSONSerialization.data(withJSONObject: envelope)
    }

    /// A redeem's `{session, reply}`: the session's tokens, if any, and the reply as an answer line; nil for a refusal.
    nonisolated private static func handoffRedeemed(_ line: Data) -> (session: (access: String, refresh: String)?, reply: Data)? {
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], answer["ok"] as? Bool == true,
              let value = answer["value"] as? [String: Any], let reply = value["reply"] as? [String: Any],
              let replyLine = try? JSONSerialization.data(withJSONObject: ["ok": true, "value": reply]) else { return nil }
        let session = value["session"] as? [String: Any]
        guard let session else { return (nil, replyLine) }
        guard let access = session["access_token"] as? String, let refresh = session["refresh_token"] as? String else {
            return (nil, handoffUnavailable)
        }
        return ((access, refresh), replyLine)
    }

    nonisolated private static func handoffRefusal(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": code, "message": message]])) ?? Data()
    }

    nonisolated private static var handoffUnavailable: Data {
        handoffRefusal("unavailable", "cmux could not be reached. Try again in a moment.")
    }

    private static func unreachable(_ message: String) -> Data {
        let answer: [String: Any] = ["ok": false, "error": ["code": "owner.unreachable", "message": message]]
        return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"ok":false,"error":{"code":"owner.unreachable","message":""}}"#.utf8)
    }
}

/// A `cmux cloud api` call's refusal: the platform's code or the call's failure kind, and its message.
public nonisolated struct CloudCallRefusal: Error, Hashable, Sendable {
    public var code: String
    public var message: String
}

/// The cmux daemon's Cloud calls (cmux-tui `cloud.<call>`) through the bundled cmux's `cmux cloud api` (cmux-tui
/// `cli/cloud_api.rs`). This only forwards: one JSON request on the child's stdin (the credential never goes in
/// argv). One answer line back, `{"ok": true, "body": B}` or `{"ok": false, "error": E}`, where `E.kind` names a
/// ``CloudAPIError`` case one for one.
public struct CloudDaemon: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    var tokens: Tokens
    private(set) var teamID: TeamID
    let appVersion: String
    /// A tagged dev build's cloud data space (``CloudConfiguration/buildSpace``); a misconfigured dev build's calls throw.
    let buildSpace: CMUXBuildSpaceState
    /// A Worker machines daemon's install token, for the call that takes an install, not a session (``listNetworks()``).
    var installToken: (@Sendable () async throws -> String)?
    /// The sign-in client sends its Stack team with every call (``pinningTeam(_:)`` fixes it); a Worker client keeps its cmux team.
    let sendsStackSession: Bool
    /// The bundled cmux that runs `cmux cloud api` and `cmux carrier secrets`; nil: no cmux is available.
    var machineIO: CloudMachineIO?
    /// The `cmux cloud api` child's run (request on stdin, stdout back); nil: ``machineIO``'s. A test passes its own.
    var daemonCall: (@Sendable (_ input: Data, _ timeout: Duration) async throws -> Data)?
    /// The account a sandboxed Run's create is sent under (``runningAs(_:)``); nil: no create is sent.
    private(set) var runAccount: RunAccount?

    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, appVersion: String, sendsStackSession: Bool,
         buildSpace: CMUXBuildSpaceState = .nightly) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.teamID = teamID
        self.appVersion = appVersion
        self.sendsStackSession = sendsStackSession
        self.buildSpace = buildSpace
    }

    /// The sign-in daemon: classic Cloud's origin (``CloudConfiguration/apiBaseURL``) with the Stack session and
    /// team, for sandboxed Runs only; a machine call on it answers 501 at once and runs nothing.
    public init(configuration: CloudConfiguration, tokens: @escaping Tokens, teamID: @escaping TeamID, appVersion: String = "cmux-next") {
        self.init(baseURL: configuration.apiBaseURL, tokens: tokens, teamID: teamID, appVersion: appVersion, sendsStackSession: true,
                  buildSpace: configuration.buildSpace)
    }

    /// The team calls go to now.
    public func currentTeam() async -> String? { await teamID() }

    /// The daemon as one owner credential with no Stack session (the feed's `cloud.owner.op`: the person's session
    /// or this Mac's install token). `run` stands in for the `cmux cloud api` child (a test's); nil: `machineIO`'s.
    public static func owner(baseURL: URL, credential: @escaping @Sendable () async throws -> String,
                             teamID: @escaping TeamID, machineIO: CloudMachineIO?,
                             run: (@Sendable (_ input: Data, _ timeout: Duration) async throws -> Data)? = nil) -> CloudDaemon {
        var daemon = CloudDaemon(baseURL: baseURL, tokens: { (try await credential(), "") }, teamID: teamID,
                                 appVersion: "cmux-next", sendsStackSession: false)
        daemon.machineIO = machineIO
        daemon.daemonCall = run
        return daemon
    }

    /// This daemon with its team fixed to `team`: every request of a create and its retries goes to the same team
    /// whatever the app switches to meanwhile. A Worker client keeps its cmux team: `team` is the app's (Stack) team id.
    public func pinningTeam(_ team: String?) -> CloudDaemon {
        guard sendsStackSession else { return self }
        var copy = self
        copy.teamID = { team }
        return copy
    }

    // MARK: Runs

    /// A Sandboxed send's client: the daemon's Runs under `account`, in `account`'s own Stack team.
    public func sending(as account: RunAccount) -> CloudDaemon {
        pinningTeam(account.team).runningAs(account)
    }

    /// This client with the account the person is sending a Run under, read as they send it
    /// (``CloudAuth/runAccount``). Every sandboxed Run's create needs one: without it none is sent.
    public func runningAs(_ account: RunAccount?) -> CloudDaemon {
        var copy = self
        copy.runAccount = account
        return copy
    }

    func sandboxSnapshot(task: String, agent: String?, timeoutMs: Int, key: String, incognito: Bool, deadline: ContinuousClock.Instant,
                                 now: @Sendable () -> ContinuousClock.Instant, follow: (@Sendable (String) async throws -> Data)?) async throws -> Data {
        // The create and its retry go with one account's credentials, read once.
        let credentials: (access: String, refresh: String)
        do { credentials = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        var pinned = self
        pinned.tokens = { credentials }
        let create = { try await pinned.createSandboxRun(task: task, agent: agent, timeoutMs: timeoutMs, idempotencyKey: key,
                                                                   incognito: incognito) }
        let createdData: Data
        do {
            createdData = try await create()
        } catch CloudAPIError.transport, CloudAPIError.timedOut {
            // The first create may have made the Run: whatever the retry says, the outcome stays
            // uncertain (`timedOut`, never a refusal the caller could take as "nothing runs").
            do { createdData = try await create() } catch { throw CloudAPIError.timedOut("cloud.runs") }
        }
        let created = try JSONSerialization.jsonObject(with: createdData) as? [String: Any]
        guard let id = created?["id"] as? String, !id.isEmpty else { throw CloudAPIError.decoding("cloud.runs: no run id") }
        if let follow { return try await follow(id) }
        while now() < deadline {
            let data: Data
            do {
                data = try await waitRun(id, timeoutMs: 10_000)
            } catch { // The Run exists: losing sight of it is "no receipt in time", never a refusal to retry past.
                throw CloudAPIError.timedOut("cloud.runs/\(id)")
            }
            // A 200 that is no Run snapshot (an array, an error body) won't turn into one: stop now.
            guard let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  snapshot["run"] is [String: Any] else { throw CloudAPIError.timedOut("cloud.runs/\(id)") }
            if snapshot["receipt"] is [String: Any] { return data }
            try Task.checkCancellation()
        }
        throw CloudAPIError.timedOut("cloud.runs/\(id)")
    }

    // MARK: Transport

    /// `cloud.<call>` with `args`: answers its body as JSON, or throws its failure as a ``CloudAPIError``.
    /// No bundled cmux is `transport` ("cmux is not available"); there is no HTTP fallback. `timeout` bounds the
    /// child (a child past it is killed: `timedOut`, since the call may have run).
    /// `auth` is the credential's kind as cmux-cloud-api reads it: `owner` (the Stack session) or `worker`
    /// (this Mac's install token). A misconfigured dev build refuses before anything runs.
    public func daemon(_ call: String, _ args: [String: any Sendable], timeout: Duration, auth: String = "owner") async throws -> Data {
        try buildSpace.check()
        let run: @Sendable (Data, Duration) async throws -> Data
        if let daemonCall {
            run = daemonCall
        } else if let machineIO {
            run = { input, timeout in try await machineIO.cloudAPI(input, timeout: timeout) }
        } else {
            throw CloudAPIError.transport("cmux is not available")
        }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        var request: [String: any Sendable] = ["call": call, "api": baseURL.absoluteString, "auth": auth, "credential": access,
                                               "app_version": appVersion, "args": args]
        if let team = await teamID() { request["team"] = team }
        let output: Data
        do {
            output = try await run(try JSONSerialization.data(withJSONObject: request), timeout)
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            // Never started: nothing ran. Started and then killed or crashed: the call may have run.
            if noAnswer.dispatched { throw CloudAPIError.timedOut("cloud.\(call)") }
            throw CloudAPIError.transport("cmux is not available")
        }
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            throw CloudAPIError.transport("cmux did not answer cloud.\(call)")
        }
        guard object["ok"] as? Bool == true else { throw Self.daemonFailure(object["error"] as? [String: Any] ?? [:], call: call, baseURL: baseURL) }
        return try JSONSerialization.data(withJSONObject: object["body"] ?? NSNull(), options: .fragmentsAllowed)
    }
}
