import CmuxNextDaemon
import Foundation

/// Where the Chief Settings panel reads and writes the engine of the brain
/// that answers this Chief (2026-10-08: the panel wrote this Mac's
/// engine.json while a cloud Chief's brain ran on cmux-lawrence).
nonisolated protocol HomeChiefEngineSource: Sendable {
    /// This Mac's brain: its traces and memory are here too.
    var isLocal: Bool { get }
    /// The paired server that runs the brain (nil: this Mac).
    var place: String? { get }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot
    /// Sets (nil: clears) one of harness, model, effort; the snapshot after.
    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot
}

/// This Mac's brain. It reads its mux home's files (engine.json, profile,
/// traces) as a read-only mirror; a set goes to the brain through this Mac's
/// Chief owner daemon (`chief.engine.set`), because the brain is the one
/// writer of engine.json and checks the value (cx-opu0: the panel wrote the
/// file itself, raced the brain and saved values the brain refused).
nonisolated struct HomeChiefLocalEngine: HomeChiefEngineSource {
    let files: HomeChiefFiles
    /// The Chief home's owner daemon; nil while it is not connected.
    let connection: @MainActor @Sendable () -> DaemonConnection?
    var isLocal: Bool { true }
    var place: String? { nil }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { files.snapshot() }

    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let connection = await connection() else { throw .localUnreachable }
        do {
            try await HomeChiefEngineSet.send(key, value, on: connection)
        } catch .unreachable {
            throw .localUnreachable
        }
        return files.snapshot()
    }
}

/// One `chief.engine.set` of one field ("default" clears it), for the local
/// and the paired-server brain alike.
nonisolated enum HomeChiefEngineSet {
    @discardableResult
    static func send(_ key: String, _ value: String?,
                     on connection: DaemonConnection) async throws(HomeChiefEngineError) -> ChiefEngineReport {
        let value = value ?? "default"
        do {
            return try await ChiefControlClient(connection).setChiefEngine(harness: key == "harness" ? value : nil,
                                                                           model: key == "model" ? value : nil,
                                                                           effort: key == "effort" ? value : nil)
        } catch let error as ChiefControlError {
            throw HomeChiefEngineError(error)
        } catch {
            throw .other(String(describing: error))
        }
    }
}

/// A paired server's brain, through that server's daemon
/// (`chief.engine.get` / `chief.engine.set` on the owner session).
nonisolated struct HomeChiefRemoteEngine: HomeChiefEngineSource {
    /// The daemon in front of the brain; nil while the server is not connected.
    let connection: @MainActor @Sendable () -> DaemonConnection?
    let place: String?
    /// The avatar stays this Mac's (`profile.json`, cosmetic).
    let files: HomeChiefFiles
    var isLocal: Bool { false }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let connection = await connection() else { throw .unreachable }
        do {
            return snapshot(try await ChiefControlClient(connection).chiefEngine())
        } catch let error as ChiefControlError {
            throw HomeChiefEngineError(error)
        } catch {
            throw .other(String(describing: error))
        }
    }

    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        guard let connection = await connection() else { throw .unreachable }
        return snapshot(try await HomeChiefEngineSet.send(key, value, on: connection))
    }

    private func snapshot(_ report: ChiefEngineReport) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: report.choice.harness, model: report.choice.model, effort: report.choice.effort,
                          avatar: files.avatar(), routeConfigured: false,
                          turns: report.recent.map(HomeEngineTurn.init(report:)))
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
