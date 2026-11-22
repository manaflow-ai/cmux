public import CmuxNextDaemon
import Foundation

/// Where the Chief Settings panel reads and writes the engine of the brain
/// that answers this Chief (2026-10-08: the panel wrote this Mac's
/// engine.json while a cloud Chief's brain ran on cmux-lawrence).
public nonisolated protocol HomeChiefEngineSource: Sendable {
    /// This Mac's brain: its traces and memory are here too.
    var isLocal: Bool { get }
    /// The paired server that runs the brain (nil: this Mac, or the Cloud service).
    var place: String? { get }
    /// The brain runs on a harness the owner picks (false: a hosted cloud Chief's brain runs
    /// one engine of its own, and the card hides the Harness row).
    var choosesHarness: Bool { get }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot
    /// Sets (nil: clears) any of harness, model, effort, speed and the reaction classifier fields in one brain write; the snapshot after.
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot
    /// The Chief's automations, oldest first (`chief.automation.list`).
    func automations() async throws(HomeChiefEngineError) -> [ChiefAutomation]
    /// Pauses, resumes, deletes or runs one automation (`chief.automation.update`); the list after.
    func updateAutomation(_ id: String, _ action: ChiefAutomationAction) async throws(HomeChiefEngineError) -> [ChiefAutomation]
}

extension HomeChiefEngineSource {
    public nonisolated var choosesHarness: Bool { true }

    /// The Chief's automations (issue 25573), oldest first; a brain with none to show (a hosted
    /// cloud Chief, whose jobs are its own `chief-auto`) answers `unsupported`.
    public nonisolated func automations() async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        throw .unsupported
    }

    /// Pauses, resumes, deletes or runs one automation; the list after the change.
    public nonisolated func updateAutomation(_ id: String, _ action: ChiefAutomationAction) async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        throw .unsupported
    }
}

/// `chief.automation.list|update` on the daemon in front of a brain, for the local and the
/// paired-server brain alike.
nonisolated enum HomeChiefAutomationCalls {
    static func list(on connection: DaemonConnection?, chief: String?) async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        guard let connection else { throw .unreachable }
        do {
            return try await ChiefControlClient(connection).chiefAutomations(chief: chief)
        } catch {
            throw HomeChiefEngineError(error)
        }
    }

    static func update(_ id: String, _ action: ChiefAutomationAction, on connection: DaemonConnection?,
                       chief: String?) async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        guard let connection else { throw .unreachable }
        do {
            return try await ChiefControlClient(connection).updateChiefAutomation(id, action, chief: chief)
        } catch {
            throw HomeChiefEngineError(error)
        }
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

    public func automations() async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        guard let connection = await connection() else { throw .localUnreachable }
        return try await HomeChiefAutomationCalls.list(on: connection, chief: chief)
    }

    public func updateAutomation(_ id: String, _ action: ChiefAutomationAction) async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        guard let connection = await connection() else { throw .localUnreachable }
        return try await HomeChiefAutomationCalls.update(id, action, on: connection, chief: chief)
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
    /// The fields a set sends: the turns' engine and the reaction classifier (a416).
    static var fieldKeys: Set<String> { ChiefControlClient.engineSetKeys }

    @discardableResult
    static func send(_ fields: [String: String?],
                     on connection: DaemonConnection, chief: String? = nil) async throws(HomeChiefEngineError) -> ChiefEngineReport {
        let sent = fields.filter { fieldKeys.contains($0.key) }.mapValues { $0 ?? "default" }
        do {
            return try await ChiefControlClient(connection).setChiefEngine(sent, chief: chief)
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

    public func automations() async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        try await HomeChiefAutomationCalls.list(on: await connection(), chief: nil)
    }

    public func updateAutomation(_ id: String, _ action: ChiefAutomationAction) async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        try await HomeChiefAutomationCalls.update(id, action, on: await connection(), chief: nil)
    }

    private func snapshot(_ report: ChiefEngineReport) -> HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: report.choice.harness, model: report.choice.model, effort: report.choice.effort,
                                         avatar: files.avatar(), routeConfigured: false,
                                         turns: report.recent.map(HomeEngineTurn.init(report:)))
        snapshot.speed = report.choice.speed
        return snapshot.offering(report)
    }
}
