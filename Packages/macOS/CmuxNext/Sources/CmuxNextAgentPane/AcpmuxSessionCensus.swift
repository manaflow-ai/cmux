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
public nonisolated enum AcpmuxQuit {
    /// Nil when acpmux has a socket but did not answer within `deadline`
    /// (unknown, not zero). No daemon (no socket, nothing listening) is zero.
    @concurrent public static func census(_ environment: AcpmuxEnvironment?, deadline: Duration = .seconds(1)) async -> AcpmuxSessionCensus? {
        guard let socket = environment?.socketPath, FileManager.default.fileExists(atPath: socket) else { return AcpmuxSessionCensus() }
        do {
            return AcpmuxSessionCensus.parse(try await AcpmuxStatusClient.sessions(socketPath: socket, deadline: deadline).value)
        } catch AcpmuxStatusClient.Failure.unreachable {
            return AcpmuxSessionCensus()
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
        /// A shutdown already started (no usable socket, daemon.lock held).
        case shutdownInProgress(pid: Int32?)
        /// No daemon, but these agent hosts (not the Chief's) are alive.
        case agentsStillRunning([String])
    }

    /// Quit Everything: ends every agent except the Home Chief's
    /// (`_acpmux/shutdown endAgents keepSessions`) and waits for the daemon
    /// to exit (kernel exit event, bounded).
    /// RED STUB (R96 late endAgents): `waitForShutdown` is ignored; the old behavior stays.
    @concurrent public static func endAgents(_ environment: AcpmuxEnvironment?, waitForShutdown: Bool = false,
                                             within: Duration = .seconds(10)) async -> EndResult {
        guard let socket = environment?.socketPath, FileManager.default.fileExists(atPath: socket) else { return .noDaemon }
        let status: AcpmuxStatus
        let chief: [String]
        do {
            status = try await AcpmuxStatusClient.status(socketPath: socket)
            chief = AcpmuxSessionCensus.chiefSessionIDs(try await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(2)).value)
            try await AcpmuxStatusClient.shutdown(socketPath: socket, endAgents: true, keepSessions: chief)
        } catch AcpmuxStatusClient.Failure.unreachable {
            return .noDaemon
        } catch {
            return .failed(String(describing: error))
        }
        guard let pid = status.pid else { return .ended }
        return await AgentPaneProcessExit.exitEvent(pid: pid, within: within) ? .ended : .failed("acpmux \(pid) did not exit")
    }
}
