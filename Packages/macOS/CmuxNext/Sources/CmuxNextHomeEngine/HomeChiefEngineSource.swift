public import CmuxNextDaemon
import Foundation

/// Where the Chief Settings panel reads and writes the engine of the brain
/// that answers this Chief (2026-10-08: the panel wrote this Mac's
/// engine.json while a cloud Chief's brain ran on cmux-lawrence).
public nonisolated protocol HomeChiefEngineSource: Sendable {
    /// This Mac's brain: its traces and memory are here too.
    var isLocal: Bool { get }
    /// The paired server that runs the brain (nil: this Mac).
    var place: String? { get }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot
    /// Sets (nil: clears) any of harness, model and effort in one brain write; the snapshot after.
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot
}

extension HomeChiefEngineSource {
    /// Sets (nil: clears) one of harness, model, effort; the snapshot after.
    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        try await set([key: value])
    }
}

/// This Mac's brain. It reads its mux home's files (engine.json, profile,
/// traces) as a read-only mirror; a set goes to the brain through this Mac's
/// Chief owner daemon (`chief.engine.set`), because the brain is the one
/// writer of engine.json and checks the value (cx-opu0: the panel wrote the
/// file itself, raced the brain and saved values the brain refused).
public nonisolated struct HomeChiefLocalEngine: HomeChiefEngineSource {
    let files: HomeChiefFiles
    /// The Chief home's owner daemon; nil while it is not connected.
    let connection: @MainActor @Sendable () -> DaemonConnection?
    /// Starts this Mac's brain when it does not answer (Home need not be
    /// open); whether a start (or the watch of a starting host) is underway.
    /// `asked`: a user's set, not a read, which also starts it after
    /// `cmux chief shutdown` (`ChiefBrainKeeper.ensure`).
    let startBrain: @MainActor @Sendable (_ asked: Bool) -> Bool
    /// The Chief this panel shows when it is not the default (chief-brains-v1):
    /// its own brain, which the owner daemon starts; nil: the default Chief.
    let chief: String?
    public var isLocal: Bool { true }
    public var place: String? { nil }

    public init(files: HomeChiefFiles, connection: @escaping @MainActor @Sendable () -> DaemonConnection?,
                startBrain: @escaping @MainActor @Sendable (_ asked: Bool) -> Bool = { _ in false }, chief: String? = nil) {
        self.files = files
        self.chief = chief
        self.connection = connection
        self.startBrain = startBrain
    }

    /// The files, with the brain's offered models and efforts when its
    /// daemon answers.
    public func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        let snapshot = files.snapshot()
        guard let connection = await connection() else { return snapshot }
        guard let report = try? await ChiefControlClient(connection).chiefEngine(chief: chief) else {
            // A read (the sidebar refreshes on its own) is no ask.
            _ = await startBrain(false)
            return snapshot
        }
        return snapshot.offering(report)
    }

    public func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let connection = await connection() else { throw .localUnreachable }
        do {
            return files.snapshot().offering(try await HomeChiefEngineSet.send(fields, on: connection, chief: chief))
        } catch .unreachable {
            throw await startBrain(true) ? .localStarting : .localUnreachable
        }
    }
}

/// One `chief.engine.set` of the given fields (nil, sent as "default", clears
/// one; a field not given is left as it is), for the local and the
/// paired-server brain alike.
nonisolated enum HomeChiefEngineSet {
    @discardableResult
    static func send(_ fields: [String: String?],
                     on connection: DaemonConnection, chief: String? = nil) async throws(HomeChiefEngineError) -> ChiefEngineReport {
        let sent = { (key: String) in fields[key].map { $0 ?? "default" } }
        do {
            return try await ChiefControlClient(connection).setChiefEngine(harness: sent("harness"), model: sent("model"),
                                                                           effort: sent("effort"), chief: chief)
        } catch let error as ChiefControlError {
            throw HomeChiefEngineError(error)
        } catch {
            throw .other(String(describing: error))
        }
    }
}

/// A paired server's brain, through that server's daemon
/// (`chief.engine.get` / `chief.engine.set` on the owner session).
public nonisolated struct HomeChiefRemoteEngine: HomeChiefEngineSource {
    /// The daemon in front of the brain; nil while the server is not connected.
    let connection: @MainActor @Sendable () -> DaemonConnection?
    public let place: String?
    /// The avatar stays this Mac's (`profile.json`, cosmetic).
    let files: HomeChiefFiles
    public var isLocal: Bool { false }

    public init(connection: @escaping @MainActor @Sendable () -> DaemonConnection?, place: String?, files: HomeChiefFiles) {
        self.connection = connection
        self.place = place
        self.files = files
    }

    public func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let connection = await connection() else { throw .unreachable }
        do {
            return snapshot(try await ChiefControlClient(connection).chiefEngine())
        } catch let error as ChiefControlError {
            throw HomeChiefEngineError(error)
        } catch {
            throw .other(String(describing: error))
        }
    }

    public func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let connection = await connection() else { throw .unreachable }
        return snapshot(try await HomeChiefEngineSet.send(fields, on: connection))
    }

    private func snapshot(_ report: ChiefEngineReport) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: report.choice.harness, model: report.choice.model, effort: report.choice.effort,
                          avatar: files.avatar(), routeConfigured: false,
                          turns: report.recent.map(HomeEngineTurn.init(report:))).offering(report)
    }
}

extension HomeEngineTurn {
    /// A turn end the brain summarized (`chief.engine.get` `recent`).
    nonisolated init(report turn: ChiefEngineReport.Turn) {
        harness = turn.harness ?? "?"
        model = turn.model
        seconds = (turn.ms ?? 0) / 1000
        tools = turn.tools ?? 0
        toolErrors = turn.toolErrors ?? 0
        cost = turn.costUSD
        reply = turn.reply
        if let usage = turn.usage {
            let read = usage.cacheRead ?? 0
            let total = read + (usage.cacheWrite ?? 0) + (usage.input ?? 0)
            hitRate = total > 0 ? read / total : nil
        } else {
            hitRate = nil
        }
    }
}
