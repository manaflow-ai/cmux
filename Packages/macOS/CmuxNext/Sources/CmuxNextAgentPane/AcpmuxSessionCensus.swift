import Foundation

/// The local acpmux daemon's agents, counted from `_acpmux/sessions` for the
/// quit dialog (plans/cmux-next/quit-persistence.md 4.1): how many agents
/// keep running after the app quits and how many are in a turn now. Read
/// once when the dialog opens; never polled.
public nonisolated struct AcpmuxSessionCensus: Sendable, Equatable {
    /// Sessions with a running agent process (`ready`, `running`, `waiting`).
    public var live: Int
    /// Sessions in a turn (`running`, or `waiting` for a permission answer).
    public var inTurn: Int
    /// Titles (else names, else ids) of the sessions in a turn, oldest turn first.
    public var inTurnNames: [String]
    /// A Home Chief session is in a turn. Chief sessions are never counted
    /// above (and never ended by a quit).
    public var chiefInTurn: Bool

    /// The tag key on every Home Chief turn and compactor session (value:
    /// the home id), agreed with the chief lane. Untagged Chief sessions are
    /// known by `chiefNamePrefix` and `chiefCompactorPresetPrefix`.
    public static let chiefTagKey = "cmux.chief"
    public static let chiefNamePrefix = "optchat-"
    public static let chiefCompactorPresetPrefix = "optchat-compact-"

    public init(live: Int = 0, inTurn: Int = 0, inTurnNames: [String] = [], chiefInTurn: Bool = false) {
        self.live = live
        self.inTurn = inTurn
        self.inTurnNames = inTurnNames
        self.chiefInTurn = chiefInTurn
    }

    /// The census of one `_acpmux/sessions` result.
    public static func parse(_ result: [String: Any]) -> AcpmuxSessionCensus {
        var census = AcpmuxSessionCensus()
        var busy: [(startedAt: Double, name: String)] = []
        for summary in summaries(result) {
            let status = summary["status"] as? String ?? ""
            let live = ["ready", "running", "waiting"].contains(status)
            let working = status == "running" || status == "waiting"
            if isChief(summary) {
                if working { census.chiefInTurn = true }
                continue
            }
            if live { census.live += 1 }
            guard working else { continue }
            census.inTurn += 1
            let startedAt = ((summary["turn"] as? [String: Any])?["startedAt"] as? NSNumber)?.doubleValue ?? .infinity
            busy.append((startedAt, displayName(summary)))
        }
        census.inTurnNames = busy.sorted { $0.startedAt < $1.startedAt }.map(\.name)
        return census
    }

    /// Ids of the Home Chief's sessions: a quit that ends agents keeps them.
    public static func chiefSessionIDs(_ result: [String: Any]) -> [String] {
        summaries(result).filter(isChief).compactMap { $0["sessionId"] as? String }
    }

    static func isChief(_ summary: [String: Any]) -> Bool {
        if let tags = summary["tags"] as? [String: Any], tags[chiefTagKey] != nil { return true }
        if let name = summary["name"] as? String, name.hasPrefix(chiefNamePrefix) { return true }
        if let harness = summary["harness"] as? String, harness.hasPrefix(chiefCompactorPresetPrefix) { return true }
        return false
    }

    private static func summaries(_ result: [String: Any]) -> [[String: Any]] {
        (result["sessions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func displayName(_ summary: [String: Any]) -> String {
        for key in ["title", "name", "sessionId"] {
            if let value = summary[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }
}

/// The local acpmux daemon at quit: one census when the dialog opens, and
/// ending its agents for Quit Everything.
public nonisolated struct AcpmuxQuit {
    public nonisolated init() {}
    /// Nil when acpmux did not answer within `deadline`, or when it is
    /// shutting down (no usable socket, daemon.lock held): unknown, not
    /// zero. With no daemon, the agent hosts that still hold their lock.
    @concurrent public static func census(_ environment: AcpmuxEnvironment?, deadline: Duration = .seconds(1)) async -> AcpmuxSessionCensus? {
        guard let environment else { return AcpmuxSessionCensus() }
        let socket = environment.socketPath
        guard FileManager.default.fileExists(atPath: socket) else { return await censusWithoutSocket(environment.home) }
        do {
            let sessions = try await AcpmuxStatusClient.sessions(socketPath: socket, deadline: deadline).value
            AcpmuxQuitProof.knownChief.withLock { $0 = Set(AcpmuxSessionCensus.chiefSessionIDs(sessions)) }
            return AcpmuxSessionCensus.parse(sessions)
        } catch AcpmuxStatusClient.Failure.unreachable {
            return await censusWithoutSocket(environment.home)
        } catch {
            return nil
        }
    }

    public enum EndResult: Equatable, Sendable {
        /// No acpmux was running.
        case noDaemon
        /// The daemon ended its agents (except the Chief's) and exited.
        case ended
        /// It did not answer or did not exit in time; the reason says why.
        case failed(String)
        /// A shutdown already started (no usable socket, daemon.lock held):
        /// the agents may still be running until it ends.
        case shutdownInProgress(pid: Int32?)
        /// No daemon, but these agent hosts (not the Chief's) hold their
        /// lock, or their lock cannot be probed.
        case agentsStillRunning([String])
    }

    /// Quit Everything: ends every agent except the Home Chief's
    /// (`_acpmux/shutdown endAgents keepSessions`) and waits for the daemon
    /// to exit (kernel exit event, bounded). With no usable socket the
    /// result comes from `AcpmuxQuitProof`, never from the missing socket
    /// alone: a shutdown that already started is `shutdownInProgress`
    /// unless `waitForShutdown` (Retry) sees it end with no agent left.
    @concurrent public static func endAgents(_ environment: AcpmuxEnvironment?, waitForShutdown: Bool = false,
                                             within: Duration = .seconds(10)) async -> EndResult {
        guard let environment else { return .noDaemon }
        let socket = environment.socketPath
        guard FileManager.default.fileExists(atPath: socket) else {
            return await withoutSocket(environment.home, waitForShutdown: waitForShutdown, within: within)
        }
        let status: AcpmuxStatus
        let chief: [String]
        do {
            status = try await AcpmuxStatusClient.status(socketPath: socket)
            chief = AcpmuxSessionCensus.chiefSessionIDs(try await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(2)).value)
            AcpmuxQuitProof.knownChief.withLock { $0 = Set(chief) }
            try await AcpmuxStatusClient.shutdown(socketPath: socket, endAgents: true, keepSessions: chief)
        } catch AcpmuxStatusClient.Failure.unreachable {
            return await withoutSocket(environment.home, waitForShutdown: waitForShutdown, within: within)
        } catch {
            return .failed(String(describing: error))
        }
        // The daemon accepted the end: it ended its agents when daemon.lock
        // is free and no non-Chief host lock is held.
        guard await AcpmuxQuitProof.waitForDaemonExit(home: environment.home, within: within) else {
            return .failed("acpmux \(status.pid.map(String.init) ?? "") did not exit")
        }
        return AcpmuxQuitProof.decide(AcpmuxQuitProof.read(home: environment.home), chief: Set(chief), daemonExited: true)
    }

    /// No usable socket: the locks decide (`AcpmuxQuitProof`). A Retry
    /// waits (bounded) for a shutdown in progress before it decides.
    @concurrent static func withoutSocket(_ home: URL, waitForShutdown: Bool, within: Duration) async -> EndResult {
        var exited = false
        if waitForShutdown, AcpmuxQuitProof.read(home: home).daemon != .free {
            exited = await AcpmuxQuitProof.waitForDaemonExit(home: home, within: within)
        }
        return AcpmuxQuitProof.decide(AcpmuxQuitProof.read(home: home), chief: AcpmuxQuitProof.knownChief.withLock { $0 },
                                      daemonExited: exited)
    }

    /// The census without a usable socket: unknown (nil) while daemon.lock
    /// is held (a shutdown in progress), else the non-Chief hosts whose lock
    /// is held or unknown.
    @concurrent static func censusWithoutSocket(_ home: URL) async -> AcpmuxSessionCensus? {
        let facts = AcpmuxQuitProof.read(home: home)
        guard facts.daemon == .free else { return nil }
        let chief = AcpmuxQuitProof.knownChief.withLock { $0 }
        return AcpmuxSessionCensus(live: Set(facts.liveHostSessions + facts.unknownHostSessions).subtracting(chief).count)
    }
}
