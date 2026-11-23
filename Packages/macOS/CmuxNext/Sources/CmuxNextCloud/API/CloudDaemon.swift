public import Foundation
import CmuxNextCompat

/// The cmux daemon's Cloud calls (cmux-tui `cloud.<call>`) through the bundled cmux's `cmux cloud api` (cmux-tui
/// `cli/cloud_api.rs`). This only forwards: one JSON request on the child's stdin (the credential never goes in
/// argv), with the classic Cloud session beside it when this client has one (`classic`, or `classic_unread` when it
/// could not be read); which call takes it, and what a refusal then means, is Rust's (cmux-cloud-api `classic_runs`).
/// One answer line back, `{"ok": true, "body": B}` or `{"ok": false, "error": E}`, where `E.kind` names a
/// ``CloudAPIError`` case one for one.
public struct CloudDaemon: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?

    let baseURL: URL
    private(set) var tokens: Tokens
    private(set) var teamID: TeamID
    let appVersion: String
    /// The sign-in client sends its Stack team with every call (``pinningTeam(_:)`` fixes it); a Worker client keeps its cmux team.
    let sendsStackSession: Bool
    /// The bundled cmux that runs `cmux cloud api` and `cmux carrier secrets`; nil: no cmux is available.
    var machineIO: CloudMachineIO?
    /// The `cmux cloud api` child's run (request on stdin, stdout back); nil: ``machineIO``'s. A test passes its own.
    var daemonCall: (@Sendable (_ input: Data, _ timeout: Duration) async throws -> Data)?
    /// The account a sandboxed Run's create is sent under (``runningAs(_:)``); nil: no create is sent.
    private(set) var runAccount: RunAccount?
    /// Classic Cloud's Run API and Stack session (``drainingClassic(_:)``): where a Run the daemon never made drains; nil: none does.
    private(set) var classicRuns: (@Sendable () async throws -> (api: URL, access: String, refresh: String, team: String?))?

    init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, appVersion: String, sendsStackSession: Bool) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.teamID = teamID
        self.appVersion = appVersion
        self.sendsStackSession = sendsStackSession
    }

    /// This daemon with its team fixed to `team`: every request of a create and its retries goes to the same team
    /// whatever the app switches to meanwhile. A Worker client keeps its cmux team: `team` is the app's (Stack) team id.
    public func pinningTeam(_ team: String?) -> CloudDaemon {
        var copy = self
        // A classic Run drains in the Stack team it was sent in.
        if let classic = classicRuns { copy.classicRuns = { let session = try await classic(); return (session.api, session.access, session.refresh, team) } }
        guard sendsStackSession else { return copy }
        copy.teamID = { team }
        return copy
    }

    /// This daemon with `classic` (the sign-in client's) as where a wait or cancel of a Run the daemon never made goes:
    /// a Run the app followed from before the daemon ran Runs drains on classic Cloud's `/api/runs` to its end
    /// (cmux-cloud-api `classic_runs`), so an upgrade never drops its result. New Runs are the daemon's alone.
    public func drainingClassic(_ classic: CloudDaemon) -> CloudDaemon {
        var copy = self
        copy.classicRuns = {
            let session = try await classic.tokens()
            return (classic.baseURL, session.access, session.refresh, await classic.teamID())
        }
        return copy
    }

    // MARK: Runs

    /// The daemon's `cloud.runs.create` for a sandboxed Run (hq#3367): one task in a Cloud chat on a new
    /// small machine, deleted after (cmux-tui `cloud.runs.*`). The key makes a retry after a lost answer return the
    /// same Run. Answers the Run's view as JSON; it holds no secrets. A non-empty `image` is refused (`run_image_invalid`).
    /// This client with the account the person is sending a Run under, read as they send it
    /// (``CloudAuth/runAccount``). Every sandboxed Run's create needs one: without it none is sent.
    /// A Sandboxed send's client: the daemon's Runs under `account`, and classic Cloud (an incognito send, a Run from before
    /// the upgrade) in `account`'s own Stack team, never this Worker client's team, which classic does not know (#39022 F1 at 1c13439a).
    public func sending(as account: RunAccount, classic: CloudDaemon) -> CloudDaemon {
        drainingClassic(classic).pinningTeam(account.team).runningAs(account)
    }

    public func runningAs(_ account: RunAccount?) -> CloudDaemon {
        var copy = self
        copy.runAccount = account
        return copy
    }

    /// The app's Cloud account a send was made under (its user id and its team id, nil: personal).
    public struct RunAccount: Sendable, Equatable {
        public var user: String
        public var team: String?
        public init(user: String, team: String?) {
            self.user = user
            self.team = team
        }
    }

    /// It goes under ``runningAs(_:)``'s account, the one the person sent under (none: `notSignedIn`, nothing sent);
    /// the daemon refuses the create (`run_account_changed`) when the app is on another one by then, so a switch
    /// never sends the task elsewhere. An `incognito` Run's reply and error are never written to the daemon's store.
    public func createSandboxRun(task: String, agent: String? = nil, image: String? = nil, timeoutMs: Int? = nil,
                                 idempotencyKey: String = UUID().uuidString, incognito: Bool = false) async throws -> Data {
        guard let runAccount else { throw CloudAPIError.notSignedIn }
        var args: [String: any Sendable] = ["task": task, "idempotencyKey": idempotencyKey,
                                            "expectedAccount": ["user_id": runAccount.user, "team_id": runAccount.team ?? ""] as [String: any Sendable]]
        if incognito { args["incognito"] = true }
        if let agent, !agent.isEmpty { args["agent"] = agent }
        if let image, !image.isEmpty { args["image"] = image }
        if let timeoutMs { args["timeoutMs"] = timeoutMs }
        return try await daemon("runs.create", args, timeout: .seconds(20))
    }

    /// The daemon's `cloud.runs.wait`: the snapshot once the Run is terminal or after
    /// `timeoutMs` (held at most 10 s), with its receipt when it has one.
    public func waitRun(_ id: String, timeoutMs: Int) async throws -> Data {
        let wait = max(0, min(timeoutMs, 10_000))
        return try await daemon("runs.wait", ["id": id, "timeoutMs": wait], timeout: .milliseconds(wait + 10_000))
    }

    /// One sandboxed Run to its end: create it, then long-poll ``waitRun(_:timeoutMs:)`` (10 s a
    /// call) until the snapshot carries its receipt. Everything (sign-in tokens included) runs under
    /// one deadline, the task's timeout plus `teardown` (boot, the last output and the VM destroy)
    /// plus a minute for the calls themselves, so the caller always gets an answer. The poll stops
    /// at the receipt, at the first error, or at that deadline (`timedOut`); the daemon deletes
    /// the machine either way. `idempotencyKey` names this one send: a create whose answer was lost is
    /// sent once more under it, which returns the same Run, never a second paid one; after a switch of
    /// account the daemon refuses it (`run_account_changed`) rather than start one under the new account, as it
    /// refuses any create once the app is off ``runningAs(_:)``'s account. Answers the final
    /// snapshot (`{run, attempts, artifacts, receipt}`) as JSON. `follow` (``SandboxRunFollower``) waits in place of the poll here.
    public func runSandbox(task: String, agent: String? = nil, timeoutMs: Int = 600_000, idempotencyKey: String = UUID().uuidString,
                           incognito: Bool = false,
                           teardown: Duration = .seconds(180), callsMargin: Duration = .seconds(60),
                           now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, follow: (@Sendable (_ id: String) async throws -> Data)? = nil) async throws -> [String: Any] {
        let bound = Duration.milliseconds(timeoutMs) + teardown + callsMargin
        let data = try await SandboxDeadline.race(bound) {
            try await self.sandboxSnapshot(task: task, agent: agent, timeoutMs: timeoutMs, key: idempotencyKey, incognito: incognito,
                                           deadline: now() + .milliseconds(timeoutMs) + teardown, now: now, follow: follow)
        }
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.decoding("cloud.runs: no snapshot")
        }
        return snapshot
    }

    func sandboxSnapshot(task: String, agent: String?, timeoutMs: Int, key: String, incognito: Bool, deadline: ContinuousClock.Instant,
                                 now: @Sendable () -> ContinuousClock.Instant, follow: (@Sendable (String) async throws -> Data)?) async throws -> Data {
        // The create and its retry go with one account's credentials, read once.
        let credentials: (access: String, refresh: String)
        do { credentials = try await tokens() } catch { throw CloudAPIError.notSignedIn }
        var pinned = self
        pinned.tokens = { credentials }
        // An incognito create goes to classic Cloud with the session read here, once, as the daemon's credentials are.
        if incognito, let classicRuns, let classic = try? await classicRuns() { pinned.classicRuns = { classic } }
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

    /// The daemon's `cloud.runs.cancel`; the Run's machine is deleted before it answers.
    public func cancelRun(_ id: String) async throws -> Data {
        try await daemon("runs.cancel", ["id": id], timeout: .seconds(60))
    }

    // MARK: Transport

    /// `cloud.<call>` with `args`: answers its body as JSON, or throws its failure as a ``CloudAPIError``.
    /// No bundled cmux is `transport` ("cmux is not available"); there is no HTTP fallback. `timeout` bounds the
    /// child (a child past it is killed: `timedOut`, since the call may have run).
    func daemon(_ call: String, _ args: [String: any Sendable], timeout: Duration) async throws -> Data {
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
        var request: [String: any Sendable] = ["call": call, "api": baseURL.absoluteString, "auth": "owner", "credential": access,
                                               "app_version": appVersion, "args": args]
        if let classicRuns {
            if let c = try? await classicRuns() {
                request["classic"] = ["api": c.api.absoluteString, "access": c.access, "refresh": c.refresh, "team": c.team ?? ""] as [String: any Sendable]
            } else {
                request["classic_unread"] = true
            }
        }
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

    /// `cmux_cloud_api`'s `Failure` JSON (`kind` and its fields) as the ``CloudAPIError`` case it names.
    static func daemonFailure(_ error: [String: Any], call: String, baseURL: URL) -> CloudAPIError {
        func text(_ name: String) -> String? { (error[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch text("kind") {
        case "timed_out": return .timedOut(text("path") ?? "cloud.\(call)")
        case "transport": return .transport(text("message") ?? "cmux did not answer cloud.\(call)")
        case "no_backend": return .noBackend(baseURL)
        case "http":
            guard let status = error["status"] as? Int else { return .decoding("cloud.\(call): no status") }
            return .http(status: status, code: text("code"), message: text("message"), action: text("action"), traceId: text("trace_id"))
        case "plan_required":
            return .planRequired(message: text("message"), upgradeURL: text("upgrade_url").flatMap { URL(string: $0) }, plan: text("plan") ?? "pro")
        case "decoding": return .decoding(text("message") ?? "cloud.\(call)")
        default: return .decoding("cloud.\(call): unreadable failure")
        }
    }
}
