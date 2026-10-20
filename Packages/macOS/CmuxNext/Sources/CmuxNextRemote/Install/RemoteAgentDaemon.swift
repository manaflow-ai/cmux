public import Foundation

/// What `cmux-tui acp --json daemon status` says about a machine's agent daemon (acpmux), read
/// over ssh. The app's keyed restart, its handoff after an install and its update check read it
/// (cx-oa6ah, cx-brq9m, cx-3r9mt). An unreadable status is nil: every caller then leaves the
/// daemon as it is (fail closed).
public struct RemoteAgentDaemonStatus: Sendable, Equatable {
    public let running: Bool
    public let ready: Bool
    public let agentHosts: Bool
    public let liveAgents: Int?
    public let remoteSessions: Int?
    public let personKey: Bool
    public let personInstance: String?

    public init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        running = object["running"] as? Bool != false
        ready = object["ready"] as? Bool == true
        agentHosts = object["agentHosts"] as? Bool == true
        liveAgents = object["liveAgents"] as? Int
        remoteSessions = object["remoteSessions"] as? Int
        personKey = object["personKey"] as? Bool == true
        personInstance = object["personInstance"] as? String
    }

    public static func read(_ host: SSHHost, environment: [String: String]) async -> RemoteAgentDaemonStatus? {
        guard let status = try? await SSHProcessRunner.run(
            SSHCommandLine().command(host, "\(host.remoteBinary) acp --json daemon status </dev/null"),
            environment: environment, deadline: .seconds(10), label: "acpmux status \(host.destination)"),
            status.status == 0 else { return nil }
        return RemoteAgentDaemonStatus(json: status.stdout)
    }

    /// The fallback rule for a cmux-tui without `agent-session-start-keyed-reason-v1` (the rule
    /// lives in cmux-tui's `keyed_restart_reason`): nothing to lose in a keyed restart.
    public var idleForKeyedRestart: Bool {
        !running || (ready && agentHosts && liveAgents == 0 && remoteSessions == 0)
    }

    /// cx-brq9m: why the handoff after an install leaves this daemon as it is; nil when the keyed
    /// restart may hand it over to the new binary (it keeps agent hosts: every hosted agent is
    /// adopted). A session proxied from a peer acpmux would end with this run, so it stays.
    public var handoffBlocker: String? {
        if !agentHosts { return "no agent hosts" }
        if remoteSessions != 0 { return "peer sessions" }
        return nil
    }

    /// cx-3r9mt: whether an automatic update may run: none runs, or it runs no live agent and no
    /// peer session and holds no other client's person key (none, or `ownInstance`). (Move to the
    /// remote cmux-tui with the other agent-daemon checks, cx-3r9mt move-to-Rust item.)
    public func idleForUpdate(ownInstance: String?) -> Bool {
        guard running else { return true }
        let otherKey = personKey && personInstance != ownInstance
        return liveAgents == 0 && remoteSessions == 0 && !otherKey
    }
}

/// A daemon run's reply to `_acpmux/person_holds` (cx-0q7o): the answer only a run that holds the
/// app's person key can give for the nonce.
public struct RemotePersonHoldsReply: Sendable {
    public let proof: String?
    public let instance: String?
}

extension SSHHost {
    /// `_acpmux/person_holds` for `nonce` over the machine's `cmux-tui acp stdio`; a nil reply when
    /// the ssh call gave none (a dropped call: cx-hd3rw asks again), with the call's last error line.
    public func personHolds(nonce: String, environment: [String: String]) async -> (reply: RemotePersonHoldsReply?, error: String) {
        let frames = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/person_holds","params":{"nonce":""# + nonce + #""}}"# + "\n"
        let held = try? await SSHProcessRunner.run(SSHCommandLine().command(self, "\(remoteBinary) acp stdio"),
                                                   input: .data(Data(frames.utf8)), environment: environment,
                                                   deadline: .seconds(30), label: "acpmux person_holds \(destination)")
        let answer = held?.stdout.split(separator: "\n").lazy
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .first { ($0["id"] as? Int) == 2 }
        let error = held.map { $0.stderr.split(separator: "\n").last.map(String.init) ?? "" } ?? "ssh failed"
        guard let answer else { return (nil, error) }
        let result = answer["result"] as? [String: Any]
        return (RemotePersonHoldsReply(proof: result?["proof"] as? String, instance: result?["instance"] as? String), error)
    }

    /// cx-3r9mt: the connect-time update check. The machine's build facts (`remote-probe --json
    /// --build-facts`; an older cmux-tui ignores the flag and answers its plain probe, which the
    /// rule counts as older) go to the app's bundled `cmux-tui remote update-need`.
    public func updateCheck(binary: URL, environment: [String: String]) async -> (probe: RemoteProbe, need: RemoteUpdateNeed)? {
        guard let facts = try? await SSHProcessRunner.run(
            SSHCommandLine().command(self, "\(remoteBinary) remote-probe --json --build-facts </dev/null"),
            environment: environment, deadline: .seconds(20), label: "remote-probe \(destination)"),
            facts.status == 0,
            let line = facts.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
            let probe = try? RemoteProbe.decode(String(line)),
            let need = await probe.updateNeed(asking: binary) else { return nil }
        return (probe, need)
    }
}

/// One keyed-restart preparation per machine at a time (two tabs starting at once share it), and
/// (`keepBusy`, the app's own status check) a busy answer kept for a minute so a busy machine
/// costs one status call per minute. The daemon's answer comes with each start, so it keeps none.
public actor RemoteApprovalPreparations {
    public static let shared = RemoteApprovalPreparations()
    private var running: [String: Task<Bool, Never>] = [:]
    private var busyUntil: [String: ContinuousClock.Instant] = [:]

    public func run(machine: String, keepBusy: Bool, _ work: @escaping @Sendable () async -> Bool) async -> Bool {
        if keepBusy, let until = busyUntil[machine], ContinuousClock.now < until { return false }
        if let task = running[machine] { return await task.value }
        // task-owner: the machine's one preparation; every caller awaits it
        let task = Task { await work() }
        running[machine] = task
        let bound = await task.value
        running[machine] = nil
        if keepBusy || bound { busyUntil[machine] = bound ? nil : ContinuousClock.now.advanced(by: .seconds(60)) }
        return bound
    }
}

/// `machine|bundled commit` pairs whose automatic update ran in this app run (cx-3r9mt): done for
/// good after a success, a skip or an offer, else not tried again before `retry(_:after:)` (a
/// build not published yet, a busy machine), so a failure is not retried on every reconnect.
public struct RemoteAutoUpdateLedger: Sendable {
    private var entries: [String: ContinuousClock.Instant?] = [:]
    public init() {}
    public func mayTry(_ key: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard let entry = entries[key] else { return true }
        guard let retry = entry else { return false }
        return now >= retry
    }
    public mutating func done(_ key: String) { entries[key] = .some(nil) }
    public mutating func retry(_ key: String, after delay: Duration) { entries[key] = .some(ContinuousClock.now.advanced(by: delay)) }
}
