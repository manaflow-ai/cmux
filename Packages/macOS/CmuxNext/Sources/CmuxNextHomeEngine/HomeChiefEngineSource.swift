import Darwin
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
    /// Sets (nil: clears) any of harness, model, effort, speed, the reaction classifier fields and the computer in one brain write; the snapshot after.
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot
}

extension HomeChiefEngineSource {
    public nonisolated var choosesHarness: Bool { true }
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
        // The daemon's operation catalog has no `computer` field yet: this one goes to the brain's tools socket,
        // the same line the daemon would forward (chief_control.rs tool_line).
        if fields.count == 1, let computer = fields["computer"] {
            switch await Self.setComputer(computer ?? "default", socket: files.muxHome.appendingPathComponent("optchat/tools.sock").path) {
            case .some(nil): return try await read()
            case .some(let refusal?): throw .other(refusal)
            case nil: throw await startBrain(true) ? .localStarting : .localUnreachable
            }
        }
        guard let connection = await connection() else { throw .localUnreachable }
        do {
            return files.snapshot().offering(try await HomeChiefEngineSet.send(fields, on: connection, chief: chief))
        } catch .unreachable {
            throw await startBrain(true) ? .localStarting : .localUnreachable
        }
    }
}

extension HomeChiefLocalEngine {
    /// One `engine set computer` line to the brain, off the main thread. Nil: the brain did not answer;
    /// `.some(nil)`: it took the value; `.some(text)`: its refusal.
    @concurrent
    static func setComputer(_ computer: String, socket path: String) async -> String?? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, var line = try? JSONSerialization.data(withJSONObject: ["tool": "engine", "action": "set", "computer": computer]) else { return nil }
        line.append(0x0A)
        guard line.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == line.count else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !reply.contains(0x0A) {
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            reply.append(contentsOf: chunk[0..<count])
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return nil }
        guard let error = answer["error"] as? [String: Any] else { return .some(nil) }
        return .some(error["message"] as? String ?? "The Chief did not take this computer.")
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

    private func snapshot(_ report: ChiefEngineReport) -> HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: report.choice.harness, model: report.choice.model, effort: report.choice.effort,
                                         avatar: files.avatar(), routeConfigured: false,
                                         turns: report.recent.map(HomeEngineTurn.init(report:)))
        snapshot.speed = report.choice.speed
        return snapshot.offering(report)
    }
}
