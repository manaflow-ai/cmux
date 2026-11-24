public import CmuxNextCloud
import Foundation
import os

/// A Cloud start's last check before the first chat opens on its machine: once the machine runs the
/// app's own machine software, its agents must reach models through the machine's edge with no provider
/// login on it (plans/cmux-next/vm-coderouter-edge.md). The machine prints its model-route report
/// (`cmux-tui acp --json machine-auth`) and Rust judges it (cmux-cloud-start-core `machine_route`, op
/// `cloud_machine_route`); the chat's own agent is read from the same report (``Agent``), so a machine whose
/// agent signs in by itself starts too. A refusal ends the start with its reason instead of a chat whose first
/// turn the provider rejects.
public struct CloudMachineRoute: Sendable {
    /// One command on the machine (the Cloud API's exec): the command and its timeout in milliseconds.
    public typealias Exec = @Sendable (_ command: String, _ timeoutMs: Int) async throws -> CloudExecResult

    /// What Rust answered about the machine's report.
    public enum Verdict: String, Decodable, Sendable {
        case ready, unsupported, invalid
        case noDaemon = "no_daemon"
        case holdsCredential = "holds_credential"
        case notEdge = "not_edge"
    }

    /// The start ends here: `verdict` says why.
    public struct Refused: Error, Sendable {
        public let verdict: Verdict
        /// The chat's agent as the report reads it (``Agent``), when the start named one.
        public var agent: Agent?
        public init(verdict: Verdict, agent: Agent? = nil) { (self.verdict, self.agent) = (verdict, agent) }
        /// The start card's text: a machine whose agent service is down says so, whatever else it holds.
        public var message: String { CloudMachineRoute.message(agent?.daemonRunning == false ? .noDaemon : verdict) }
    }

    /// The report's bound on the machine: one exec, well under the Cloud API's 5 minutes.
    public static let timeoutMs = 60_000

    private let exec: Exec
    /// The exec as given, with no start of a machine that does not run (``report()``).
    private let plain: Exec

    public init(exec: @escaping Exec, start: (@Sendable () async throws -> Void)? = nil) {
        self.exec = Self.startingWhenStopped(exec, start: start)
        plain = exec
        machineID = nil
    }

    /// The route of Cloud machine `machineID`, whose commands run through the Cloud API's exec. `start` starts or resumes
    /// the machine when the exec finds it not running (``startingWhenStopped(_:start:)``); nil refuses as the route does.
    public init(api: CloudAPIClient, machineID: String, start: (@Sendable () async throws -> Void)? = nil) {
        self.init(machineID: machineID, exec: { try await api.exec(machineID, command: $0, timeoutMs: $1) }, start: start)
    }

    /// ``init(api:machineID:start:)`` with its exec given (tests): a machine its start left not running ends the start
    /// with its reason and Retry on `machineID`, not the route's bare refusal.
    public init(machineID: String, exec: @escaping Exec, start: (@Sendable () async throws -> Void)?) {
        let started = Self.startingWhenStopped(exec, start: start)
        let retried: Exec = { command, timeoutMs in
            do { return try await started(command, timeoutMs) } catch let refusal as CloudAPIError where refusal.isMachineNotRunning {
                throw CloudMoveFailure(message: await CloudMoveStrings.moveFailed(refusal.text()), retry: .move(machineID: machineID))
            }
        }
        self.exec = start == nil ? started : retried
        plain = exec
        self.machineID = machineID
    }

    /// A refused resume whose own error is the start's answer, never a generic failure with Retry: the person's cancel,
    /// an approval still pending, a quota, or a plan's refusal (the caller checks the plan's own forms too).
    public nonisolated static func keepsItsError(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        var code = (error as? CloudAppOpFailure)?.code ?? ""
        if case .http(_, let sent?, _, _, _) = error as? CloudAPIError { code = sent }
        // Whole words of the code (`cmux.cloud.plan_required`, `cloud.quota.vm_limit`), so `control_plane` is no plan.
        return !Set(code.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init)).isDisjoint(with: ["approval", "quota", "plan"])
    }

    /// `exec`, except that a refusal because the machine does not run (`vm_not_running`: the Cloud API's exec and file
    /// routes run only on a machine whose record reads running) runs `start` and sends the command once more. The start's
    /// link can be up on a machine whose record does not run: a click's link connect starts a paused machine and answers
    /// before its record does, and an idle pause can land as the link comes up. The start's route check was the first
    /// exec there, and its refusal ended the start with "the machine is not running; start it first" (cmux#47638). The
    /// start runs at most once for every command this exec sends (a later refusal reuses its outcome, never starts again);
    /// a second refusal, or any other one, is thrown as it came.
    public static func startingWhenStopped(_ exec: @escaping Exec, start: (@Sendable () async throws -> Void)?) -> Exec {
        guard let start else { return exec }
        let once = StartOnce(start)
        return { command, timeoutMs in
            do {
                return try await exec(command, timeoutMs)
            } catch let refusal as CloudAPIError where refusal.isMachineNotRunning {
                do { try await once.run() } catch { throw StartFailed(error: error) }
                return try await exec(command, timeoutMs)
            }
        }
    }

    /// The machine's start failed: its error is the route check's answer, thrown at once and never read as a route that
    /// could not be read (which would update a machine that does not run first).
    nonisolated struct StartFailed: Error { let error: any Error }

    /// `error` as the route check's caller reads it: a failed start's own error.
    private nonisolated static func unwrapped(_ error: any Error) -> any Error { (error as? StartFailed)?.error ?? error }

    /// One start, shared by every caller: the first runs it, the others await its outcome.
    private actor StartOnce {
        private let start: @Sendable () async throws -> Void
        private var started: Task<Void, any Error>?
        init(_ start: @escaping @Sendable () async throws -> Void) { self.start = start }
        func run() async throws {
            // task-owner: started; the one start of a route check, awaited by each refusal that needs it
            let task = started ?? Task { [start] in try await start() }
            started = task
            // A cancelled start (the person stopped the chat's start) ends its machine start too.
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }

    /// The machine ``init(api:machineID:)`` named; a ``prepare(_:)`` refusal retries on it.
    private let machineID: String?

    /// A Cloud start's machine before its first chat: its agents reach models through its edge, and it serves
    /// what the start needs (`serves`: the daemon's capabilities). The machine is checked first and updated
    /// (`update`, ``afterUpdate(within:_:)``) only when it lacks one of them: a machine whose host updater follows
    /// its channel never takes this app's build when it is older (a DEV build of a branch), and an unconditional
    /// update held every start for 8 minutes before going on as it was (2026-11-16). A refusal is the start's
    /// failure, its reason as the start card shows it, with a retry on the same machine.
    ///
    /// A machine whose software predates the report (``Verdict/unsupported``) is not refused: the app's update
    /// never moves a machine back, so a machine on a newer build than this app's that still lacks the report
    /// (an image ahead of a DEV build's branch), or an app with no machine build to install, could never pass
    /// and every start on a new machine ended here. Its chat starts on the software the image came with; a
    /// machine that does report and is not routed is still refused. A capability the start then lacks ends it
    /// where it is used (``CloudOutdatedMachine/requireCapability(holds:lacks:relink:within:update:missing:)``, ``tooOld``).
    ///
    /// `carriesConnection`: the chat's own model connection goes with its agent launch (a connection the person
    /// set up, sent as the launch's start credentials), so the chat does not use the machine's route or login: acpmux
    /// gives the launch that credential and removes every other (`agent_credentials.rs` `UNSET`). A machine that reports
    /// no route (``Verdict/notEdge``) or holds a provider login (``Verdict/holdsCredential``) then starts as it is, as
    /// `cmux chat --on vm:new` always did (2026-11-17).
    ///
    /// `family`: the chat's agent (``CloudSetup/family(of:)``), judged on its own (``Agent``): a machine whose Claude
    /// signs in by itself (a `claude setup-token` token in its env, its saved sign-in, a key of its own) starts a Claude
    /// chat with no connection and no gateway, as acpmux launches it on that sign-in (`claude_cloud_auth.rs`: a sign-in
    /// of its own keeps own). Refusing every machine with a login on it ended those starts with "holds its own provider
    /// sign-in" (cmux#45773). A machine whose agent service is down is still refused.
    ///
    /// `ahead`: the machine's report as ``report()`` read it before this start (a warm spare's, ``CloudSpareReadiness``,
    /// which gives it to one start only, while the agent service run this app last keyed is the one it was read under).
    /// A report that says the chat starts (``startsAhead(_:agent:carriesConnection:)``) is the check: no command runs
    /// on the machine now (1.9 to 2.5 s of every start, 2026-11-21). Any other one is read again, so a refusal is always
    /// the machine's answer now. The app does not see a restart it did not make: an agent service that went down since
    /// the read ends the start at the chat's own start instead of here.
    public func prepare(serves: @MainActor () -> Bool = { true }, carriesConnection: Bool = false, family: String? = nil, ahead: String? = nil,
                        requiresCredentialCapability: Bool = false,
                        _ update: @escaping @Sendable () async -> Void) async throws {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
        var checked: (verdict: Verdict, agent: Agent?)?
        if await serves() {
            if let ahead {
                let route = await Self.judged(ahead, family: family, acceptsUnreportedAgent: requiresCredentialCapability)
                if Self.startsAhead(route.verdict, agent: route.agent, carriesConnection: carriesConnection) {
                    logger.info("cloud start chat: \(machineID ?? "", privacy: .public) serves this start by its report read ahead (\(route.verdict.rawValue, privacy: .public), \(route.agent?.summary ?? "no agent", privacy: .public)); no update")
                    return
                }
            }
            do { checked = try await read(family: family, acceptsUnreportedAgent: requiresCredentialCapability) } catch {
                // A machine that could not be started, or stays stopped, or a cancel: its own error now, with no update first.
                if error is StartFailed || error is CloudMoveFailure || error is CancellationError { throw Self.unwrapped(error) }
            }
        }
        if let route = checked {
            if Self.starts(route.verdict, agent: route.agent, carriesConnection: carriesConnection) {
                logger.info("cloud start chat: \(machineID ?? "", privacy: .public) already serves this start (\(route.verdict.rawValue, privacy: .public), \(route.agent?.summary ?? "no agent", privacy: .public)); no update")
                return
            }
            // A machine that serves the start and whose agent reaches no model gets no route from an update: the route is
            // the Cloud service's, not the machine software's. The chat needs its own connection; no update wait first.
            if Self.needsConnection(route.verdict, agent: route.agent, carriesConnection: carriesConnection) {
                logger.info("cloud start chat: \(machineID ?? "", privacy: .public) has no model route or sign-in for the chat's agent and the chat carries no connection")
                throw NeedsConnection()
            }
        }
        logger.info("cloud start chat: bringing \(machineID ?? "", privacy: .public) to this app's machine software")
        do {
            try await afterUpdate(family: family, acceptsUnreportedAgent: requiresCredentialCapability, update)
            if requiresCredentialCapability, !(await serves()) { throw tooOldFailure }
        } catch let refused as Refused {
            if requiresCredentialCapability, !(await serves()) { throw tooOldFailure }
            if refused.verdict == .unsupported {
                logger.info("cloud start chat: \(machineID ?? "", privacy: .public) has no model-route report after its update, or the update did not end in time; starting on its own software")
                return
            }
            // The update gave the machine no route, but the chat's agent reaches a model anyway: the machine's own sign-in,
            // or the chat's own connection with its launch, to a daemon that takes one.
            if Self.starts(refused.verdict, agent: refused.agent, carriesConnection: carriesConnection) {
                if await serves() {
                    logger.info("cloud start chat: \(machineID ?? "", privacy: .public) has no model route; the chat's agent signs in by itself or carries its connection")
                    return
                }
                // The chat's connection would reach a model, but the machine's software could not be brought to one that
                // takes it (Codex's sign-in with ChatGPT needs a daemon from 2026-11-18): say that, not "not routed".
                if carriesConnection { throw CloudMoveFailure(message: Self.tooOld, retry: machineID.map { .move(machineID: $0) }) }
            }
            if Self.needsConnection(refused.verdict, agent: refused.agent, carriesConnection: carriesConnection) { throw NeedsConnection() }
            throw CloudMoveFailure(message: refused.message, retry: machineID.map { .move(machineID: $0) })
        }
    }

    private var tooOldFailure: CloudMoveFailure {
        CloudMoveFailure(message: Self.tooOld, retry: machineID.map { .move(machineID: $0) })
    }

    /// The machine reports no model route (``Verdict/notEdge``) or only a login the chat's agent does not use, and the chat
    /// carries no connection of its own (a team's shared key, or nothing chosen): its agent could reach no model. The Cloud
    /// service gives machines no route today (cmux-platform#1489: a create carrying the edge rule never binds), so this is
    /// every such start, and the way on is the person setting the agent up. A Claude or Codex start shows Set up Cloud
    /// (`cloud_setup_required`, `AgentPaneCloudStart.needsConnectionReply`), which starts again once a connection of the
    /// person's own serves the agent; only an agent Cloud cannot set up ends with ``message`` and no Retry. Either ends at
    /// once, not after an update wait (cmux#45773).
    public struct NeedsConnection: Error, Sendable {
        public init() {}
        /// The card's text where Set up Cloud cannot be shown (an agent outside ``CloudSetup/families``).
        public var message: String { CloudMachineRoute.message(.notEdge) }
    }

    /// What the machine's report says about one agent (`claude` or `codex`), read from the same output Rust judged
    /// (``Verdict`` is the machine's as a whole: one login on it, for any agent, was ``Verdict/holdsCredential``). The
    /// pinned FFI's `cloud_machine_route` answers for the whole machine only, so this reads the report's fields here.
    public nonisolated struct Agent: Equatable, Sendable {
        /// acpmux, which launches the agent, runs.
        public var daemonRunning: Bool
        /// The agent's base URL is the machine's edge with its placeholder key.
        public var routed: Bool
        /// The agent signs in by itself on the machine: a login file of its own (`login_files`), a credential variable of
        /// its own in the daemon's env (`credential_env`: `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`), or a real
        /// key of its own (`agents.<family>.key` `other`).
        public var signsIn: Bool

        public init(daemonRunning: Bool, routed: Bool, signsIn: Bool) {
            (self.daemonRunning, self.routed, self.signsIn) = (daemonRunning, routed, signsIn)
        }

        /// The credential variables (`acpmux machine-auth` `CREDENTIAL_VARS`) each agent reads.
        static let credentialVariables: [String: Set<String>] = [
            "claude": ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"],
            "codex": ["CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CHATGPT_ACCESS_TOKEN"],
        ]

        /// The report in the machine's output, as Rust's `report` finds it: the last JSON object line that names `agents`.
        static func report(in stdout: String) -> [String: Any]? {
            stdout.split(whereSeparator: \.isNewline).reversed().lazy.compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any]
            }.first { $0["agents"] != nil }
        }

        /// `family`'s reading of the machine's output; nil for no report (``report(in:)``) or a family the report
        /// does not name.
        public static func read(_ stdout: String, family: String, acceptsUnreportedAgent: Bool = false) -> Agent? {
            let report = report(in: stdout)
            guard let report, let agents = report["agents"] as? [String: Any] else { return nil }
            let daemonRunning = (report["daemon"] as? [String: Any])?["running"] as? Bool == true
            guard let agent = agents[family] as? [String: Any] else {
                return acceptsUnreportedAgent ? Agent(daemonRunning: daemonRunning, routed: false, signsIn: false) : nil
            }
            let logins = (report["login_files"] as? [[String: Any]] ?? []).contains { $0["agent"] as? String == family }
            let variables = Set(report["credential_env"] as? [String] ?? []).intersection(credentialVariables[family] ?? []).isEmpty == false
            return Agent(daemonRunning: daemonRunning,
                         routed: agent["edge_routed"] as? Bool == true && agent["key"] as? String == "placeholder",
                         signsIn: logins || variables || agent["key"] as? String == "other")
        }

        var summary: String { "agent daemon=\(daemonRunning) routed=\(routed) signsIn=\(signsIn)" }
    }

    /// Whether a machine that answered `verdict` ends the start with ``NeedsConnection``: the chat brings no connection of
    /// its own and its agent (`agent`, when known) has neither the machine's route nor a sign-in of its own there.
    public nonisolated static func needsConnection(_ verdict: Verdict, agent: Agent? = nil, carriesConnection: Bool) -> Bool {
        guard !carriesConnection else { return false }
        switch verdict {
        case .notEdge, .holdsCredential:
            guard let agent else { return verdict == .notEdge }
            return agent.daemonRunning && !agent.routed && !agent.signsIn
        case .ready, .unsupported, .invalid, .noDaemon:
            return false
        }
    }

    /// Whether a start goes on with a machine that answered `verdict`, with no update: routed, or on software from before
    /// the report, or, with its agent service running, the chat's agent reaches a model (its route, its own sign-in on the
    /// machine, or the chat's own connection with its launch). With no ``Agent`` reading, a machine that holds a login is
    /// refused and an unrouted one starts only on the chat's connection, as before.
    public nonisolated static func starts(_ verdict: Verdict, agent: Agent? = nil, carriesConnection: Bool) -> Bool {
        switch verdict {
        case .ready, .unsupported:
            return true
        case .notEdge, .holdsCredential:
            guard let agent else { return verdict == .notEdge && carriesConnection }
            return agent.daemonRunning && (carriesConnection || agent.routed || agent.signsIn)
        case .invalid, .noDaemon:
            return false
        }
    }

    private struct Request: Encodable { var stdout: String? }
    private struct Reply: Decodable { var command: String, verdict: Verdict? }

    /// How long a start waits for its machine to run the app's own machine software (the update pushes the
    /// app's pinned build and restarts the machine's services on it) before it gives up with ``Refused``:
    /// ``CloudOutdatedMachine/startUpdateWait``, which says why (it was 8 minutes until 2026-11-16).
    public static let updateDeadline: Duration = CloudOutdatedMachine.startUpdateWait

    /// Runs `update` (the app's update of the machine to its own machine software, a no-op for a machine
    /// already on it or on a newer build), at most `deadline`, then ``verify(family:)``. A missed deadline is
    /// ``Refused`` with ``Verdict/unsupported``.
    public func afterUpdate(within deadline: Duration = updateDeadline, family: String? = nil, acceptsUnreportedAgent: Bool = false, _ update: @escaping @Sendable () async -> Void) async throws {
        guard await CloudOutdatedMachine.bounded(deadline, clock: ContinuousClock(), { await update() }) != nil else {
            throw Refused(verdict: .unsupported)
        }
        try await verify(family: family, acceptsUnreportedAgent: acceptsUnreportedAgent)
    }

    /// Returns when the machine's agents reach models through its edge; throws ``Refused`` otherwise, with `family`'s
    /// ``Agent`` reading. An exec that fails (the machine went away, the route timed out) throws its own error.
    public func verify(family: String? = nil, acceptsUnreportedAgent: Bool = false) async throws {
        let route: (verdict: Verdict, agent: Agent?)
        do { route = try await read(family: family, acceptsUnreportedAgent: acceptsUnreportedAgent) } catch { throw Self.unwrapped(error) }
        guard route.verdict == .ready else { throw Refused(verdict: route.verdict, agent: route.agent) }
    }

    /// What Rust answers about the machine's model-route report (``verify(family:)``'s reading), and `family`'s ``Agent``
    /// in the same output. An exec that fails throws.
    func read(family: String?, acceptsUnreportedAgent: Bool = false) async throws -> (verdict: Verdict, agent: Agent?) {
        guard let command = CloudStartCore().call("cloud_machine_route", Request(stdout: nil), as: Reply.self)?.command else { return (.invalid, nil) }
        return await Self.judged(try await exec(command, Self.timeoutMs).stdout, family: family, acceptsUnreportedAgent: acceptsUnreportedAgent)
    }

    /// What Rust answers about `stdout`, the output of the report's command, and `family`'s ``Agent`` in it.
    static func judged(_ stdout: String, family: String?, acceptsUnreportedAgent: Bool = false) async -> (verdict: Verdict, agent: Agent?) {
        let verdict = CloudStartCore().call("cloud_machine_route", Request(stdout: stdout), as: Reply.self)?.verdict ?? .invalid
        return (verdict, await agentReading(stdout, family: family, acceptsUnreportedAgent: acceptsUnreportedAgent))
    }

    /// The machine's report now, for a later start's check (``prepare(serves:carriesConnection:family:ahead:_:)``): the
    /// command's output when it holds a report (``isReport(_:)``) that says its agent service runs, else nil (the
    /// command failed, the machine does not run, its software predates the report, or its agent service is down:
    /// nothing a start could go on by). Never starts the machine, whatever start this route was made with.
    public func report() async -> String? {
        guard let command = CloudStartCore().call("cloud_machine_route", Request(stdout: nil), as: Reply.self)?.command,
              let stdout = try? await plain(command, Self.timeoutMs).stdout else { return nil }
        let verdict = CloudStartCore().call("cloud_machine_route", Request(stdout: stdout), as: Reply.self)?.verdict
        guard verdict.map(Self.isReport) == true, await Self.serviceRuns(stdout) else { return nil }
        return stdout
    }

    /// The machine-side command that makes the reserved folder of the machine's first home chat and warms an agent in it
    /// (`cmux-tui acp --json warm-home --wait`, acpmux `hub/pool/reserved.rs`), run as the work user as ``report()``'s is.
    /// Prints `{"accepted":true,"state":"ready",...}` once the agent is up; prints nothing when the machine's cmux-tui
    /// predates the verb.
    static let warmHomeCommand = "c=/home/cmux/.cmux/bin/cmux-tui; [ -x \"$c\" ] || c=cmux-tui; "
        + "if [ \"$(id -u)\" = 0 ] && id cmux >/dev/null 2>&1; then "
        + "set -- setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux; "
        + "else set --; fi; \"$@\" \"$c\" acp --json warm-home --wait 2>/dev/null; true"

    /// Warms the first home chat of a spare machine ahead of its claim (leo: "a cmux Cloud chat's create-to-first-text p50
    /// <= 3000 ms"): whether its agent is ready in the folder that chat will take. Never starts the machine.
    public func warmHome() async -> Bool {
        guard let stdout = try? await plain(Self.warmHomeCommand, Self.timeoutMs).stdout else { return false }
        return Self.warmHomeReady(stdout)
    }

    /// Whether `stdout` is the warm-home answer of an agent that is ready.
    nonisolated static func warmHomeReady(_ stdout: String) -> Bool {
        guard let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return answer["accepted"] as? Bool == true && answer["state"] as? String == "ready"
    }

    /// Whether the report in `stdout` says the machine's agent service runs (`daemon.running`), read off the main actor
    /// as ``agentReading(_:family:)``. Rust names a login before a service that is down (``Verdict/holdsCredential``),
    /// so the verdict alone does not say.
    @concurrent nonisolated static func serviceRuns(_ stdout: String) async -> Bool {
        (Agent.report(in: stdout)?["daemon"] as? [String: Any])?["running"] as? Bool == true
    }

    /// A verdict Rust read off a report the machine printed: never the answers for no report at all
    /// (``Verdict/unsupported``, ``Verdict/invalid``) or for a service that is down (``Verdict/noDaemon``).
    nonisolated static func isReport(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .ready, .notEdge, .holdsCredential: true
        case .unsupported, .invalid, .noDaemon: false
        }
    }

    /// Whether a report read ahead is the start's check: a real report (``isReport(_:)``) that says the chat starts
    /// (``starts(_:agent:carriesConnection:)``). One that says anything else is read again on the machine.
    public nonisolated static func startsAhead(_ verdict: Verdict, agent: Agent? = nil, carriesConnection: Bool) -> Bool {
        isReport(verdict) && starts(verdict, agent: agent, carriesConnection: carriesConnection)
    }

    /// `family`'s ``Agent`` in the machine's output, read off the main actor: the parse splits the whole output and
    /// decodes each line's JSON.
    @concurrent nonisolated static func agentReading(_ stdout: String, family: String?, acceptsUnreportedAgent: Bool) async -> Agent? {
        family.flatMap { Agent.read(stdout, family: $0, acceptsUnreportedAgent: acceptsUnreportedAgent) }
    }

    /// A start whose machine's software lacks a capability it needs (a chosen model connection's start credentials)
    /// and that the machine could not be updated to: its start card's text, with Retry on the same machine.
    public nonisolated static var tooOld: String {
        String(localized: "cloud.machineRoute.tooOld",
               defaultValue: "This Cloud machine's software is too old for this cmux and couldn't be updated. Try again in a few minutes, or update cmux.",
               table: "Cloud", bundle: .localizedModule)
    }

    nonisolated static func message(_ verdict: Verdict) -> String {
        switch verdict {
        case .ready:
            ""
        case .unsupported, .invalid:
            String(localized: "cloud.machineRoute.outdated",
                   defaultValue: "This Cloud machine's software couldn't be updated to match this app, so its agents can't reach models. Try again, or use a new machine.",
                   table: "Cloud", bundle: .localizedModule)
        case .noDaemon:
            String(localized: "cloud.machineRoute.noDaemon",
                   defaultValue: "The agent service on this Cloud machine didn't start. Try again in a moment.",
                   table: "Cloud", bundle: .localizedModule)
        case .holdsCredential:
            String(localized: "cloud.machineRoute.holdsCredential",
                   defaultValue: "This Cloud machine holds its own provider sign-in, so its agents skip the Cloud service's model route. Start the chat on a new machine.",
                   table: "Cloud", bundle: .localizedModule)
        case .notEdge:
            String(localized: "cloud.machineRoute.notEdge",
                   defaultValue: "This Cloud machine's agents aren't routed through the Cloud service yet. Try again, or start the chat on a new machine.",
                   table: "Cloud", bundle: .localizedModule)
        }
    }
}
