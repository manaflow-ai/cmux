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
    /// Saves a file the person dropped into session `sessionId` on the machine that runs it (an
    /// ssh peer's chat: on that peer) and answers its path there. Throws
    /// ``AgentPaneFilePutFailure``. Never starts a daemon.
    func putFile(sessionId: String, name: String, data: Data) async throws -> String
    func putFile(sessionId: String, name: String, file: URL) async throws -> String
    /// A person asked to restart acpmux from this app's own binary after a refusal named another
    /// binary on the socket (``AgentPaneHostError/daemonRefused(holder:socketPath:reason:executable:owner:)``
    /// with an owner): stops that daemon, keeping its sessions, so the next handshake starts this
    /// app's. Only while `owner`, the binary the refusal named, still holds the socket. True when
    /// it stopped.
    func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool
    /// The acpmux whose socket is `socket`, for an answer the host gives itself on the person's
    /// behalf (``AgentPaneAskAnswer``): nil when this host's daemon listens elsewhere, or it has none.
    func answerEnvironment(socket: String) async -> AcpmuxEnvironment?
}

extension AgentPaneHostProviding {
    /// Hosts without a daemon answer a reconnect like a first handshake.
    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await handshake(sessionId: sessionId)
    }

    public func prewarm() async throws {}

    /// Hosts without a daemon know no session folders.
    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }

    /// Hosts without a daemon have none to restart.
    public func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool { false }

    /// Hosts without a daemon answer nothing themselves.
    public func answerEnvironment(socket: String) async -> AcpmuxEnvironment? { nil }

    /// Hosts without a daemon take no files.
    public func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        throw AgentPaneFilePutFailure.unsupported
    }

    public func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: file)
        }.value
        return try await putFile(sessionId: sessionId, name: name, data: data)
    }
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
    /// The daemon could not be started or reached; `cause` says why
    /// (``AcpmuxFailureCause``) and its log has the details.
    case daemonFailed(logPath: String, cause: AcpmuxFailureCause = .other)
    /// The daemon ran an old version that an update replaced; the app handed it
    /// off and its owner starts the bundled one. The page retries on its own.
    case daemonRestarting
    /// Nothing listens on the socket and this handshake may not start a
    /// daemon (``AgentPaneHostProviding/reconnectHandshake(sessionId:)``).
    case daemonStopped
    /// Nothing listens on the Chief home's socket: only the Chief host starts
    /// that daemon, never a tab (cx-ebm.54).
    case chiefStopped
    /// A daemon answers on `socketPath`, but this build may not use it: it runs another
    /// executable (`holder`, the cmux app that owns it, when known) or failed the peer check
    /// for `reason`. Its log says nothing, since the daemon itself never saw a failure.
    /// `executable` is this app's own acpmux: the message's shutdown command runs it. `owner`:
    /// the binary that holds the socket, when this app may stop it and start its own
    /// (``AgentPaneHostProviding/restartAcpmux(owner:)``); nil when it may not.
    case daemonRefused(holder: String?, socketPath: String, reason: String, executable: String = "acpmux",
                       owner: AcpmuxSocketOwner? = nil)
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
    /// Whether the daemon gets the session offer tools now (`AcpmuxEnvironment.offersSessionTools`:
    /// ``AgentPaneSuggestedTasks/forNextDaemon``: `sessions.promptSuggestions` or the forcing tunable), read at each
    /// daemon start: a change applies to the next daemon this app starts, never to the one running.
    private let offersSessionTools: @Sendable () -> Bool
    /// Whether the daemon keeps the agent message runaway guard on now (`AcpmuxEnvironment.agentPairGuard`,
    /// the `agent.pairGuard` Debug Settings toggle), read at each daemon start like the offer tools.
    private let agentPairGuard: @Sendable () -> Bool
    /// The guard's cap and window in seconds now (`agent.pairCap`, `agent.pairWindow`), read with it.
    private let agentPairCap: @Sendable () -> (messages: Int, windowSeconds: Int)
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
    /// Heals a daemon this app does not own that runs a replaced bundle: its
    /// owner hands it off and starts the bundled one (the Chief host,
    /// `ChiefAcpmuxHeal`). Returns whether it did. Nil: this host cannot heal.
    private let healReplaced: (@Sendable () async -> Bool)?
    /// Restarts this app's own daemon when it is alive but stops answering, while
    /// `restartsUnresponsive` (the `agent.restartUnresponsiveAcpmux` toggle) is on.
    private let unresponsive: AcpmuxUnresponsiveWatch
    private let restartsUnresponsive: @Sendable () -> Bool

    /// - Parameter healReplaced: called once per daemon pid when a daemon this
    ///   host does not start (`startsDaemons: false`) runs from a replaced bundle.
    public init(environment: AcpmuxEnvironment?, startsDaemons: Bool = true,
                healReplaced: (@Sendable () async -> Bool)? = nil) {
        self.init(environment: environment, startsDaemons: startsDaemons, healReplaced: healReplaced, unresponsive: .shared)
    }

    init(environment: AcpmuxEnvironment?, startsDaemons: Bool = true, healReplaced: (@Sendable () async -> Bool)? = nil,
         unresponsive: AcpmuxUnresponsiveWatch,
         restartsUnresponsive: @escaping @Sendable () -> Bool = { AgentPaneTunables.restartUnresponsiveAcpmux.value }) {
        self.resolveEnvironment = { environment }
        self.computerUse = { [:] }
        self.offersSessionTools = { environment?.offersSessionTools ?? false }
        self.agentPairGuard = { environment?.agentPairGuard ?? true }
        self.agentPairCap = { (environment?.agentPairCap ?? 20, environment?.agentPairWindowSeconds ?? 600) }
        self.daemonReady = { _ in }
        self.startsDaemons = startsDaemons
        self.healReplaced = healReplaced
        self.unresponsive = unresponsive
        self.restartsUnresponsive = restartsUnresponsive
    }

    /// Looks for acpmux (bundled, PATH, install directories) on the actor,
    /// off the main thread, at the first handshake that needs it.
    public init(resolve: @escaping @Sendable () -> AcpmuxEnvironment?,
                computerUse: @escaping @Sendable () -> [String: String] = { [:] },
                offersSessionTools: @escaping @Sendable () -> Bool = { AgentPaneSuggestedTasks.forNextDaemon.isOn },
                agentPairGuard: @escaping @Sendable () -> Bool = { AgentPaneTunables.agentPairGuard.value },
                agentPairCap: @escaping @Sendable () -> (messages: Int, windowSeconds: Int) = {
                    (Int(AgentPaneTunables.agentPairCap.value), Int(AgentPaneTunables.agentPairWindow.value))
                },
                daemonReady: (@Sendable (String) async -> Void)? = nil) {
        self.resolveEnvironment = resolve
        self.computerUse = computerUse
        self.offersSessionTools = offersSessionTools
        self.agentPairGuard = agentPairGuard
        self.agentPairCap = agentPairCap
        self.daemonReady = daemonReady ?? { _ in }
        self.startsDaemons = true
        self.healReplaced = nil
        self.unresponsive = .shared
        self.restartsUnresponsive = { AgentPaneTunables.restartUnresponsiveAcpmux.value }
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

    public func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        if environment == nil { environment = resolveEnvironment() }
        guard let environment else { throw AgentPaneFilePutFailure.unsupported }
        return try await AcpmuxStatusClient.putFile(socketPath: environment.socketPath, sessionId: sessionId, name: name, data: data)
    }

    public func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        if environment == nil { environment = resolveEnvironment() }
        guard let environment else { throw AgentPaneFilePutFailure.unsupported }
        return try await AcpmuxStatusClient.putFile(socketPath: environment.socketPath, sessionId: sessionId, name: name, file: file)
    }

    /// Only a host that starts daemons restarts one: never the Chief home's (cx-ebm.54).
    public func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool {
        guard startsDaemons else { return false }
        if environment == nil { environment = resolveEnvironment() }
        guard let environment, !environment.isAttached, owner.socketPath == environment.socketPath else { return false }
        return await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner)
    }

    /// This host's own daemon, only when `socket` is its socket: the Chief home's host answers for
    /// the Chief home's chats, the app's for the app's.
    public func answerEnvironment(socket: String) async -> AcpmuxEnvironment? {
        if environment == nil { environment = resolveEnvironment() }
        guard let environment, environment.socketPath == socket else { return nil }
        return environment
    }

    private func endpoint(startsDaemon asked: Bool) async throws -> AcpmuxWebEndpoint {
        if environment == nil { environment = resolveEnvironment() }
        guard var environment else {
            Self.logger.error("acpmux environment unresolved startsDaemon=\(asked && startsDaemons, privacy: .public)")
            throw AgentPaneHostError.acpmuxNotFound
        }
        // An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) is another app's: only look, as the Chief's tabs do.
        let owned = startsDaemons && !environment.isAttached
        let startsDaemon = asked && owned
        if let task = inFlight[startsDaemon] { return try await task.value }
        // A reconnect during a start waits for that daemon instead of
        // reporting it stopped.
        if !startsDaemon, let task = inFlight[true] { return try await task.value }
        environment.computerUse = computerUse()
        environment.offersSessionTools = offersSessionTools()
        environment.agentPairGuard = agentPairGuard()
        (environment.agentPairCap, environment.agentPairWindowSeconds) = agentPairCap()
        let daemonSocket = environment.socketPath
        Self.logger.info("acpmux environment resolved executable=\(environment.executable.path, privacy: .public) home=\(environment.home.path, privacy: .public) socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
        // task-owner: stored in inFlight and cleared when it settles; callers await its value
        var heal: (@Sendable (Int32) async -> Bool)?
        if let healReplaced {
            heal = { @Sendable (pid: Int32) async -> Bool in await self.healOnce(pid: pid, healReplaced) }
        }
        // Only a daemon this app owns is ever restarted for not answering. The watch follows it
        // also with the toggle off (an answer then still ends a streak); the toggle is read at
        // each miss and right before a restart.
        let watch = owned ? unresponsive : nil
        let restarts = restartsUnresponsive
        let task = Task {
            try await Self.findOrStart(environment, startsDaemon: startsDaemon, owned: owned, heal: heal, watch: watch, restarts: restarts)
        }
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
        let deadline = ContinuousClock.now + .seconds(3)
        var delay: Duration = .milliseconds(100)
        // wakeup-allow: bounded retry while the daemon recreates its Unix socket; this exits at the deadline or on any non-transient refusal.
        while true {
            do {
                let result = try await AcpmuxServerPeer.call(socketPath: environment.socketPath, method: "_acpmux/status",
                                                             params: [:], executable: environment.executable,
                                                             allowForeign: true, deadline: .seconds(2))
                return try AcpmuxStatus(result).endpoint()
            } catch let refusal as AcpmuxServerPeer.Refusal where refusal.isTransientRestart && ContinuousClock.now < deadline {
                let remaining = deadline - ContinuousClock.now
                // wakeup-allow: bounded backoff for the transient socket handoff; the deadline limits this sleep to three seconds.
                try await Task.sleep(for: min(delay, remaining))
                delay = min(delay * 2, .milliseconds(500))
            }
        }
    }

    /// The pane's error for a peer check that refused the daemon on `environment`'s socket,
    /// logged with who holds it, so "acpmux did not start" never hides a running daemon.
    /// `reason` replaces the refusal's own description (a replaced bundle names itself).
    /// `startsDaemons`: whether this host may replace the daemon (``restartAcpmux(owner:)``); the refusal
    /// then carries the binary on the socket as its owner, for Restart acpmux only.
    static func refused(_ refusal: AcpmuxServerPeer.Refusal, _ environment: AcpmuxEnvironment,
                        reason: String? = nil, startsDaemons: Bool = true) -> AgentPaneHostError {
        var holder: String?
        var refusedPath: String?
        if case .otherExecutable(let path) = refusal {
            holder = AcpmuxServerPeer.holderName(executablePath: path)
            refusedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let found = AcpmuxSocketOwner.read(socketPath: environment.socketPath)
        // This app's own acpmux on the socket is never replaced by itself, and a refusal that named
        // a binary offers to replace only that one: a daemon that took the socket since is not it.
        let owner = found.flatMap { owner in
            owner.path == environment.executable.resolvingSymlinksInPath().path
                || refusedPath.map({ $0 != owner.path }) == true ? nil : owner
        }
        AcpmuxFailureLog(logPath: environment.logPath).record(.peerRefused, detail: "\(environment.socketPath): \(refusal.description)")
        logger.error("acpmux at \(environment.socketPath, privacy: .public) refused: \(refusal.description, privacy: .public); held by \(holder ?? "unknown", privacy: .public); this app runs \(environment.executable.path, privacy: .public)")
        return .daemonRefused(holder: holder, socketPath: environment.socketPath, reason: reason ?? refusal.description,
                              executable: environment.executable.path, owner: startsDaemons ? owner : nil)
    }

    /// Each stale daemon's heal, by pid: one heal per daemon, however many panes ask,
    /// and a later ask gets the same answer.
    private var heals: [Int32: Task<Bool, Never>] = [:]

    private func healOnce(pid: Int32, _ heal: @escaping @Sendable () async -> Bool) async -> Bool {
        if let running = heals[pid] { return await running.value }
        // task-owner: kept in `heals` for this actor's life; one per stale daemon pid
        let task = Task { await heal() }
        heals[pid] = task
        return await task.value
    }

    /// A shutdown removes `daemon.pid`; kill -9 or a crash leaves it naming a dead process,
    /// and a daemon nobody reaped leaves a zombie, which `kill(pid, 0)` still reports alive.
    private static func crashed(_ home: URL) -> Bool {
        guard let text = try? String(contentsOf: home.appendingPathComponent("daemon.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return !agentPaneProcessIsRunning(pid)
    }

    /// Logs `cause` to the daemon's log and makes the error the pane shows.
    private static func failure(_ environment: AcpmuxEnvironment, _ cause: AcpmuxFailureCause, detail: String) -> AgentPaneHostError {
        AcpmuxFailureLog(logPath: environment.logPath).record(cause, detail: detail)
        return .daemonFailed(logPath: environment.logPath, cause: cause)
    }

    /// The refusal of a daemon of another acpmux home on this app's socket: it is another app's
    /// or tag's. Never hand it off, stop it, key it or use it.
    private static func foreignHome(_ status: AcpmuxStatus, _ environment: AcpmuxEnvironment) -> AgentPaneHostError {
        logger.error("acpmux socket=\(environment.socketPath, privacy: .public) serves home=\(status.home ?? "", privacy: .public), not this app's home=\(environment.home.path, privacy: .public)")
        AcpmuxFailureLog(logPath: environment.logPath).record(.foreignHome, detail: "home \(status.home ?? "?")")
        let holder = status.pid.flatMap(AcpmuxVersionHandoff.executablePath(pid:)).map(AcpmuxServerPeer.holderName(executablePath:))
        return .daemonRefused(holder: holder, socketPath: environment.socketPath,
                              reason: "it serves the acpmux home \(status.home ?? ""), not \(environment.home.path)",
                              executable: environment.executable.path)
    }

    /// `_acpmux/status` of a daemon that just started, or won the start: waits up to 3 s while
    /// its socket is still being bound, as ``verifiedEndpoint(_:)`` does. Nil when none answers.
    private static func startedStatus(_ environment: AcpmuxEnvironment) async -> AcpmuxStatus? {
        let deadline = ContinuousClock.now + .seconds(3)
        var delay: Duration = .milliseconds(100)
        // wakeup-allow: bounded retry while the started daemon binds its Unix socket; this exits at the deadline or on any other failure.
        while true {
            do {
                return try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
            } catch AcpmuxStatusClient.Failure.unreachable where ContinuousClock.now < deadline {
                // wakeup-allow: bounded backoff for the socket bind; the deadline limits this sleep to three seconds.
                do { try await Task.sleep(for: min(delay, deadline - ContinuousClock.now)) } catch { return nil }
                delay = min(delay * 2, .milliseconds(500))
            } catch {
                logger.error("acpmux status after a start failed error=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// - Parameters:
    ///   - watch: counts status calls that answer or miss their deadline and restarts this app's
    ///     own daemon once it stopped answering (``AcpmuxUnresponsiveWatch``); nil: never.
    ///   - restarts: the `agent.restartUnresponsiveAcpmux` toggle, read at each miss and right
    ///     before the restart.
    private static func findOrStart(_ environment: AcpmuxEnvironment, startsDaemon: Bool, owned: Bool,
                                    heal: (@Sendable (Int32) async -> Bool)?,
                                    watch: AcpmuxUnresponsiveWatch? = nil,
                                    restarts: @escaping @Sendable () -> Bool = { false }) async throws -> AcpmuxWebEndpoint {
        // cmux NEXT adopts its old acpmux home before it asks or starts a daemon (cx-is1kf.9).
        await AcpmuxEnvironment.adoptBuildHomes()
        // The status call below answered: a later deadline in this lookup is not a missed status call.
        var answered = false
        // This lookup took a stray daemon over or handed a stale one off: Settings' daemon line
        // says restarting until it ends.
        var handedOff = false
        defer { if handedOff { AcpmuxDaemonSummary.mark(home: environment.home, restarting: false) } }
        do {
            let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
            answered = true
            watch?.answered(home: environment.home.standardizedFileURL.path)
            // A daemon of another acpmux home answers on this socket: it is another app's or
            // tag's. Never hand it off, stop it or use it.
            guard status.serves(home: environment.home) else { throw Self.foreignHome(status, environment) }
            // After an update the daemon may be the previous build's: hand it
            // off (its agents keep running under their hosts) and start ours.
            // A reconnect never stops or starts a daemon. It still gives a daemon that restarted
            // this launch's person key (a signed daemon takes it by this app's signature), so
            // the reconnected pane's allows keep working.
            guard startsDaemon else {
                // An attached daemon keeps its owner's person key and Computer Use endpoint.
                if !environment.isAttached {
                    _ = await AcpmuxPersonKey.enroll(status, environment: environment, mayHandOff: false)
                    await AcpmuxComputerUse.enroll(environment)
                }
                do {
                    return try await Self.verifiedEndpoint(environment)
                } catch let refusal as AcpmuxServerPeer.Refusal {
                    // A daemon that only runs an old version an update replaced: its owner
                    // hands it off (its agents are adopted) and starts the bundled one.
                    if let pid = status.pid, AcpmuxVersionHandoff.replaced(pid: pid) {
                        AcpmuxFailureLog(logPath: environment.logPath).record(.replacedBundle, detail: "pid \(pid): \(refusal)")
                        if let heal, await heal(pid) {
                            logger.info("acpmux \(pid) ran a replaced bundle; its owner restarts it")
                            throw AgentPaneHostError.daemonRestarting
                        }
                        throw Self.refused(refusal, environment, reason: AcpmuxFailureCause.replacedBundle.logText, startsDaemons: owned)
                    }
                    throw Self.refused(refusal, environment, startsDaemons: owned)
                }
            }
            // After an update, or for this launch's person key (`AcpmuxPersonKey`): a daemon
            // that cannot take the key is handed off and ours starts with it. A daemon no cmux
            // install runs (`~/.local/bin/acpmux`) is taken over first (`AcpmuxStrayDaemon`).
            let stray = await AcpmuxStrayDaemon.handOffIfStray(status, environment: environment)
            let stale = stray ? true : await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment)
            handedOff = stale
            let stopped = stale ? true : await AcpmuxPersonKey.enroll(status, environment: environment)
            guard stopped else {
                await AcpmuxComputerUse.enroll(environment)
                return try await Self.verifiedEndpoint(environment)
            }
        } catch AcpmuxStatusClient.Failure.unreachable {
            logger.info("acpmux status unreachable socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
            // Nothing listens on the socket: start a daemon below, unless
            // the user stopped it. A reconnect starts one only after a crash
            // (cx-6bgzj); the new daemon adopts the agents still running.
            guard startsDaemon || owned && crashed(environment.home) else {
                throw owned || environment.isAttached ? AgentPaneHostError.daemonStopped : AgentPaneHostError.chiefStopped
            }
        } catch AcpmuxStatusClient.Failure.noWebSocket {
            logger.error("acpmux status returned no websocket socket=\(environment.socketPath, privacy: .public)")
            throw failure(environment, .noWebSocket, detail: environment.socketPath)
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux status timed out socket=\(environment.socketPath, privacy: .public)")
            // A daemon that stays alive but stopped answering holds its lock: no new one could
            // start. Once it is stopped, start one below; it adopts the agent hosts.
            guard !answered, let watch, await watch.restartIfStuck(environment, enabled: restarts) else { throw AgentPaneHostError.timedOut }
        } catch let error as AgentPaneHostError {
            throw error
        } catch let refusal as AcpmuxServerPeer.Refusal {
            throw Self.refused(refusal, environment, startsDaemons: owned)
        } catch {
            logger.error("acpmux status failed error=\(String(describing: error), privacy: .public)")
            throw failure(environment, .other, detail: String(describing: error))
        }
        do {
            let endpoint = try await AcpmuxDaemonLauncher.launch(environment)
            // A signed daemon ignores the spawn key: it takes the key by this app's signature.
            if let status = await Self.startedStatus(environment), status.serves(home: environment.home) {
                _ = await AcpmuxPersonKey.enroll(status, environment: environment)
                await AcpmuxComputerUse.enroll(environment)
            }
            return endpoint
        } catch AcpmuxDaemonLauncher.Failure.exited {
            logger.error("acpmux launcher exited before ready log=\(environment.logPath, privacy: .public)")
            // Another client may have started the daemon first; the loser exits because the
            // socket is taken. Ask the winner, checked as on the paths above: it serves this
            // app's home, and it gets this launch's person key before a pane connects. A signed
            // daemon gets the key only by enroll, and a pane that connects first proves nothing,
            // so every Allow stayed refused until the app relaunched (cosmic-gray, 2026-10-24).
            // A reconnect's rule: this branch never stops the winner (`mayHandOff: false`).
            do {
                guard let status = await Self.startedStatus(environment) else {
                    throw failure(environment, .exited, detail: "no daemon answers after the launch exited")
                }
                guard status.serves(home: environment.home) else { throw Self.foreignHome(status, environment) }
                _ = await AcpmuxPersonKey.enroll(status, environment: environment, mayHandOff: false)
                await AcpmuxComputerUse.enroll(environment)
                return try await Self.verifiedEndpoint(environment)
            } catch let error as AgentPaneHostError {
                throw error
            } catch let refusal as AcpmuxServerPeer.Refusal {
                throw Self.refused(refusal, environment, startsDaemons: owned)
            } catch {
                throw failure(environment, .exited, detail: String(describing: error))
            }
        } catch AcpmuxDaemonLauncher.Failure.refused(let why) {
            logger.error("acpmux daemon refused to start: \(why, privacy: .public)")
            throw failure(environment, .refused(why), detail: why)
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux launcher timed out log=\(environment.logPath, privacy: .public)")
            throw AgentPaneHostError.timedOut
        } catch {
            logger.error("acpmux launcher failed error=\(String(describing: error), privacy: .public) log=\(environment.logPath, privacy: .public)")
            throw failure(environment, .other, detail: String(describing: error))
        }
    }
}
