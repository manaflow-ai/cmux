public import CmuxNextDesign
public import Foundation
import os

/// Produces the handshake for a pane. The App picks the live acpmux host or
/// the mock; the pane never knows which.
public nonisolated protocol AgentPaneHostProviding: Sendable {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// Starts the daemon before a page is visible. Callers may treat this as
    /// best effort because the normal page handshake still reports failures.
    func prewarm() async throws
    /// The handshake for a page that lost its daemon. Starts one only after a
    /// crash, so a daemon the user stopped stays stopped.
    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// The folder of the daemon's session `sessionId`, nil when it has none.
    /// Never starts a daemon.
    func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder?
}

extension AgentPaneHostProviding {
    /// Hosts without a daemon answer a reconnect like a first handshake.
    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await handshake(sessionId: sessionId)
    }

    public func prewarm() async throws {}

    /// Hosts without a daemon know no session folders.
    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
}

/// A host's own refusal of a handshake, already in the user's language (a chat on another
/// machine that its machine refused to start); the pane says it as it is.
public nonisolated protocol AgentPaneHostRefusal: Error {
    var userMessage: String { get }
    /// The machine the refused chat belongs to, for the composer's machine chip (cx-k21v): a chat
    /// of another machine never shows this Mac's name, also while it is refused. Nil: unknown.
    var machineName: String? { get }
}

public extension AgentPaneHostRefusal {
    var machineName: String? { nil }
}

/// Why the live host could not produce a handshake.
public nonisolated enum AgentPaneHostError: Error, Equatable, Sendable {
    /// No `acpmux` executable in the app bundle, on `PATH`, or in the usual
    /// install directories.
    case acpmuxNotFound
    /// The daemon could not be started or reported no WebSocket listener;
    /// details are in its log.
    case daemonFailed(logPath: String)
    /// Nothing listens on the socket and this handshake may not start a
    /// daemon (``AgentPaneHostProviding/reconnectHandshake(sessionId:)``).
    case daemonStopped
    /// Nothing listens on the Chief home's socket: only the Chief host starts
    /// that daemon, never a tab (cx-ebm.54).
    case chiefStopped
    case timedOut
}

/// Finds the running acpmux daemon, or starts one, and hands the page its
/// WebSocket endpoint. Concurrent handshakes (several panes opening at once)
/// share one lookup, so they never race to spawn two daemons. A reconnect
/// only looks; it never starts a daemon.
public actor AcpmuxHost: AgentPaneHostProviding {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    private let resolveEnvironment: @Sendable () -> AcpmuxEnvironment?
    /// The Computer Use socket and agent token now (`AcpmuxEnvironment.computerUse`),
    /// read at each daemon start, since Computer Use turns on and off while the app runs.
    private let computerUse: @Sendable () -> [String: String]
    /// Whether the daemon gets the session offer tools now (`AcpmuxEnvironment.offersSessionTools`,
    /// the `agent.suggestedTasks` Debug Settings toggle), read at each daemon start: a toggle applies to the next daemon
    /// this app starts, never to the one already running.
    private let offersSessionTools: @Sendable () -> Bool
    /// Whether the daemon's sessions get the session tools now (`AcpmuxEnvironment.sessionTools`,
    /// the `agent.sessionTools` Debug Settings toggle), read at each daemon start like the offer tools.
    private let sessionTools: @Sendable () -> Bool
    /// Called with the daemon socket after each successful find or start, so
    /// the Computer Use helper v2 can register this daemon.
    private let daemonReady: @Sendable (String) async -> Void
    /// Kept only once found, so acpmux installed after the first chat is picked up.
    private var environment: AcpmuxEnvironment?
    /// The lookup in flight, by whether it may start a daemon.
    private var inFlight: [Bool: Task<AcpmuxWebEndpoint, any Error>] = [:]
    /// False for a daemon this app does not own (the Chief home's, which the
    /// Chief host starts): every handshake then only looks, as a reconnect
    /// does. It never stops, hands off or starts that daemon, so a subagent
    /// tab never ends the Chief's acpmux under its host (cx-ebm.54).
    private let startsDaemons: Bool

    public init(environment: AcpmuxEnvironment?, startsDaemons: Bool = true) {
        self.resolveEnvironment = { environment }
        self.computerUse = { [:] }
        self.offersSessionTools = { environment?.offersSessionTools ?? false }
        self.sessionTools = { environment?.sessionTools ?? true }
        self.daemonReady = { _ in }
        self.startsDaemons = startsDaemons
    }

    /// Looks for acpmux (bundled, PATH, install directories) on the actor,
    /// off the main thread, at the first handshake that needs it.
    public init(resolve: @escaping @Sendable () -> AcpmuxEnvironment?,
                computerUse: @escaping @Sendable () -> [String: String] = { [:] },
                offersSessionTools: @escaping @Sendable () -> Bool = { AgentPaneTunables.suggestedTasks.value },
                sessionTools: @escaping @Sendable () -> Bool = { AgentPaneTunables.sessionTools.value },
                daemonReady: (@Sendable (String) async -> Void)? = nil) {
        self.resolveEnvironment = resolve
        self.computerUse = computerUse
        self.offersSessionTools = offersSessionTools
        self.sessionTools = sessionTools
        self.daemonReady = daemonReady ?? { _ in }
        self.startsDaemons = true
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(connection(try await endpoint(startsDaemon: true)), sessionId: sessionId)
    }

    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(connection(try await endpoint(startsDaemon: false)), sessionId: sessionId)
    }

    /// The host socket's connection, with this daemon launch's LocalApp token read now, on the
    /// actor (it changes at every launch, so it is read at every handshake and reconnect).
    private func connection(_ endpoint: AcpmuxWebEndpoint) -> AcpmuxConnection {
        AcpmuxConnection(endpoint: endpoint, home: environment?.home, socketPath: environment?.socketPath,
                         executable: environment?.executable)
    }

    public func prewarm() async throws {
        _ = try await endpoint(startsDaemon: true)
    }

    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? {
        if environment == nil { environment = resolveEnvironment() }
        guard let environment else { throw AgentPaneHostError.acpmuxNotFound }
        return try await AcpmuxStatusClient.sessionFolder(socketPath: environment.socketPath, sessionId: sessionId)
    }

    private func endpoint(startsDaemon asked: Bool) async throws -> AcpmuxWebEndpoint {
        let startsDaemon = asked && startsDaemons
        if let task = inFlight[startsDaemon] { return try await task.value }
        // A reconnect during a start waits for that daemon instead of
        // reporting it stopped.
        if !startsDaemon, let task = inFlight[true] { return try await task.value }
        if environment == nil { environment = resolveEnvironment() }
        guard var environment else {
            Self.logger.error("acpmux environment unresolved startsDaemon=\(startsDaemon, privacy: .public)")
            throw AgentPaneHostError.acpmuxNotFound
        }
        environment.computerUse = computerUse()
        environment.offersSessionTools = offersSessionTools()
        environment.sessionTools = sessionTools()
        let daemonSocket = environment.socketPath
        Self.logger.info("acpmux environment resolved executable=\(environment.executable.path, privacy: .public) home=\(environment.home.path, privacy: .public) socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
        // task-owner: stored in inFlight and cleared when it settles; callers await its value
        let owned = startsDaemons
        let task = Task { try await Self.findOrStart(environment, startsDaemon: startsDaemon, owned: owned) }
        inFlight[startsDaemon] = task
        defer { if inFlight[startsDaemon] == task { inFlight[startsDaemon] = nil } }
        let endpoint = try await task.value
        await daemonReady(daemonSocket)
        return endpoint
    }

    /// The pane's endpoint from `_acpmux/status` read on a connection whose server peer is the
    /// acpmux this app runs (cx-fcaq review P3-1): a squatter on the unix socket cannot point the
    /// pane at another daemon's WebSocket. Another cmux install's daemon (NIGHTLY shares
    /// `~/.acpmux` with older builds) is accepted under ``AcpmuxServerPeer``'s rules 1 and 2; it is never
    /// enrolled, so its allows stay refused. (The pane also checks the port's listener and the
    /// accepted end before its first frame.)
    private static func verifiedEndpoint(_ environment: AcpmuxEnvironment) async throws -> AcpmuxWebEndpoint {
        let result = try await AcpmuxServerPeer.call(socketPath: environment.socketPath, method: "_acpmux/status",
                                                     params: [:], executable: environment.executable,
                                                     allowForeign: true, deadline: .seconds(2))
        return try AcpmuxStatus(result).endpoint()
    }

    /// A shutdown removes `daemon.pid`; kill -9 or a crash leaves it naming a dead process.
    private static func crashed(_ home: URL) -> Bool {
        guard let text = try? String(contentsOf: home.appendingPathComponent("daemon.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private static func findOrStart(_ environment: AcpmuxEnvironment, startsDaemon: Bool, owned: Bool) async throws -> AcpmuxWebEndpoint {
        // cmux NEXT adopts its old acpmux home before it asks or starts a daemon (cx-is1kf.9).
        await AcpmuxEnvironment.adoptBuildHomes()
        do {
            let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
            // A daemon of another acpmux home answers on this socket: it is another app's or
            // tag's. Never hand it off, stop it or use it.
            guard status.serves(home: environment.home) else {
                logger.error("acpmux socket=\(environment.socketPath, privacy: .public) serves home=\(status.home ?? "", privacy: .public), not this app's home=\(environment.home.path, privacy: .public)")
                throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
            }
            // After an update the daemon may be the previous build's: hand it
            // off (its agents keep running under their hosts) and start ours.
            // A reconnect never stops or starts a daemon. It still gives a daemon that restarted
            // this launch's person key (a signed daemon takes it by this app's signature), so
            // the reconnected pane's allows keep working.
            guard startsDaemon else {
                _ = await AcpmuxPersonKey.enroll(status, environment: environment, mayHandOff: false)
                return try await Self.verifiedEndpoint(environment)
            }
            // After an update, or for this launch's person key (`AcpmuxPersonKey`): a daemon
            // that cannot take the key is handed off and ours starts with it.
            let stale = await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment)
            let stopped = stale ? true : await AcpmuxPersonKey.enroll(status, environment: environment)
            guard stopped else { return try await Self.verifiedEndpoint(environment) }
        } catch AcpmuxStatusClient.Failure.unreachable {
            logger.info("acpmux status unreachable socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
            // Nothing listens on the socket: start a daemon below, unless
            // the user stopped it. A reconnect starts one only after a crash
            // (cx-6bgzj); the new daemon adopts the agents still running.
            guard startsDaemon || owned && crashed(environment.home) else {
                throw owned ? AgentPaneHostError.daemonStopped : AgentPaneHostError.chiefStopped
            }
        } catch AcpmuxStatusClient.Failure.noWebSocket {
            logger.error("acpmux status returned no websocket socket=\(environment.socketPath, privacy: .public)")
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux status timed out socket=\(environment.socketPath, privacy: .public)")
            throw AgentPaneHostError.timedOut
        } catch let error as AgentPaneHostError {
            throw error
        } catch {
            logger.error("acpmux status failed error=\(String(describing: error), privacy: .public)")
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        }
        do {
            let endpoint = try await AcpmuxDaemonLauncher.launch(environment)
            // A signed daemon ignores the spawn key: it takes the key by this app's signature.
            if let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath) {
                _ = await AcpmuxPersonKey.enroll(status, environment: environment)
            }
            return endpoint
        } catch AcpmuxDaemonLauncher.Failure.exited {
            logger.error("acpmux launcher exited before ready log=\(environment.logPath, privacy: .public)")
            // Another client may have started the daemon first; the loser
            // exits because the socket is taken. Ask the winner.
            do {
                return try await Self.verifiedEndpoint(environment)
            } catch {
                throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
            }
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux launcher timed out log=\(environment.logPath, privacy: .public)")
            throw AgentPaneHostError.timedOut
        } catch {
            logger.error("acpmux launcher failed error=\(String(describing: error), privacy: .public) log=\(environment.logPath, privacy: .public)")
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        }
    }
}
