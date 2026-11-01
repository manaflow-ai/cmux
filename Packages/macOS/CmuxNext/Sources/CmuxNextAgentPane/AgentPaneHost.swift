public import CmuxNextDesign
public import Foundation
import CmuxNextCompat
import os

/// Produces the handshake for a pane. The App picks the live acpmux host or
/// the mock; the pane never knows which.
public nonisolated protocol AgentPaneHostProviding: Sendable {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// Starts the daemon before a page is visible. Callers may treat this as
    /// best effort because the normal page handshake still reports failures.
    func prewarm() async throws
    /// The peers listed by the same daemon the composer Environment picker reads.
    func chatPeers() async throws -> [AgentChatPeer]
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
    /// A person asked to restart this app's own acpmux while the pane of `sessionId` waits for it
    /// (the pane's "Restart agent service"): stops that daemon, keeping its sessions, so the next
    /// handshake starts a new one. Only the host the pane's handshake goes to, only one that
    /// starts its daemon, and only while a lookup waits on it. True when it stopped.
    func restartStuckAcpmux(sessionId: String?) async -> Bool
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

    public func chatPeers() async throws -> [AgentChatPeer] { [] }

    /// Hosts without a daemon know no session folders.
    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }

    /// Hosts without a daemon have none to restart.
    public func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool { false }

    /// Hosts without a daemon have none to restart.
    public func restartStuckAcpmux(sessionId: String?) async -> Bool { false }

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
    /// Nothing listens on the Chief home's socket yet, and its owner (the Chief host) was asked
    /// to start (#25570). The page retries on its own and connects once the host is up.
    case chiefStarting
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
    /// Asks the owner of a daemon this app does not start (the Chief host, `ChiefBrainKeeper`)
    /// to start when nothing listens on its socket. Returns whether a start is on its way: then
    /// the handshake fails as ``AgentPaneHostError/chiefStarting`` and the page retries, instead
    /// of waiting for someone to open Home (#25570). Nil: nobody to ask.
    private let startOwner: (@Sendable () async -> Bool)?
    /// The app's local daemons (``AcpmuxLocalDaemons``): its marks say restarting in Settings while
    /// a handoff runs; it keeps two Restart acpmux from stopping two daemons.
    private let daemons: AcpmuxLocalDaemons
    /// Stops this app's own daemon when a person asks (``restartStuckAcpmux(sessionId:)``); one per host.
    private let daemonStop = AcpmuxDaemonStop()
    /// Sends the Computer Use endpoint to the daemon (`AcpmuxComputerUse.enroll`; a recorder in tests).
    private let enrollComputerUse: @Sendable (AcpmuxEnvironment) async -> Void
    /// Gets this Mac's approver key to each daemon this host connects (``AgentPanePeerApprover``); nil: none.
    private let peerApprover: AgentPanePeerApprover?

    /// - Parameters:
    ///   - daemons: the app's one ``AcpmuxLocalDaemons``, shared by every host.
    ///   - healReplaced: called once per daemon pid when a daemon this
    ///     host does not start (`startsDaemons: false`) runs from a replaced bundle.
    ///   - startOwner: called when nothing listens on the socket of a daemon this host does not
    ///     start: asks its owner to start it; true when a start is on its way.
    ///   - peerApprover: the app's approver key, given to each daemon this host connects.
    public init(daemons: AcpmuxLocalDaemons, environment: AcpmuxEnvironment?, startsDaemons: Bool = true,
                healReplaced: (@Sendable () async -> Bool)? = nil,
                startOwner: (@Sendable () async -> Bool)? = nil, peerApprover: AgentPanePeerApprover? = nil) {
        self.resolveEnvironment = { environment }
        self.computerUse = { [:] }
        self.offersSessionTools = { environment?.offersSessionTools ?? false }
        self.agentPairGuard = { environment?.agentPairGuard ?? true }
        self.agentPairCap = { (environment?.agentPairCap ?? 20, environment?.agentPairWindowSeconds ?? 600) }
        self.daemonReady = { _ in }
        self.enrollComputerUse = { await AcpmuxComputerUse.enroll($0) }
        self.startsDaemons = startsDaemons
        self.healReplaced = healReplaced
        self.startOwner = startOwner
        self.daemons = daemons
        self.peerApprover = peerApprover
    }

    /// Looks for acpmux (bundled, PATH, install directories) on the actor,
    /// off the main thread, at the first handshake that needs it. `daemons`: the app's one
    /// ``AcpmuxLocalDaemons``, shared by every host.
    public init(daemons: AcpmuxLocalDaemons, resolve: @escaping @Sendable () -> AcpmuxEnvironment?,
                computerUse: @escaping @Sendable () -> [String: String] = { [:] },
                offersSessionTools: @escaping @Sendable () -> Bool = { AgentPaneSuggestedTasks.forNextDaemon.isOn },
                agentPairGuard: @escaping @Sendable () -> Bool = { AgentPaneTunables.agentPairGuard.value },
                agentPairCap: @escaping @Sendable () -> (messages: Int, windowSeconds: Int) = {
                    (Int(AgentPaneTunables.agentPairCap.value), Int(AgentPaneTunables.agentPairWindow.value))
                },
                daemonReady: (@Sendable (String) async -> Void)? = nil, peerApprover: AgentPanePeerApprover? = nil) {
        self.init(daemons: daemons, resolve: resolve, computerUse: computerUse, offersSessionTools: offersSessionTools,
                  agentPairGuard: agentPairGuard, agentPairCap: agentPairCap, daemonReady: daemonReady,
                  enrollComputerUse: { await AcpmuxComputerUse.enroll($0) }, peerApprover: peerApprover)
    }

    /// `enrollComputerUse` sends the Computer Use endpoint (a recorder in tests).
    init(daemons: AcpmuxLocalDaemons, resolve: @escaping @Sendable () -> AcpmuxEnvironment?,
         computerUse: @escaping @Sendable () -> [String: String] = { [:] },
         offersSessionTools: @escaping @Sendable () -> Bool = { AgentPaneSuggestedTasks.forNextDaemon.isOn },
         agentPairGuard: @escaping @Sendable () -> Bool = { AgentPaneTunables.agentPairGuard.value },
         agentPairCap: @escaping @Sendable () -> (messages: Int, windowSeconds: Int) = {
             (Int(AgentPaneTunables.agentPairCap.value), Int(AgentPaneTunables.agentPairWindow.value))
         },
         daemonReady: (@Sendable (String) async -> Void)? = nil,
         enrollComputerUse: @escaping @Sendable (AcpmuxEnvironment) async -> Void, peerApprover: AgentPanePeerApprover? = nil) {
        self.resolveEnvironment = resolve
        self.computerUse = computerUse
        self.offersSessionTools = offersSessionTools
        self.agentPairGuard = agentPairGuard
        self.agentPairCap = agentPairCap
        self.daemonReady = daemonReady ?? { _ in }
        self.enrollComputerUse = enrollComputerUse
        self.startsDaemons = true
        self.healReplaced = nil
        self.startOwner = nil
        self.daemons = daemons
        self.peerApprover = peerApprover
    }

    /// The Computer Use endpoint changed (`ComputerUseHelperDaemon.onEndpointChange`: a replaced
    /// agent token, or the endpoint published or withdrawn): gives it to this app's running acpmux
    /// now. acpmux reads it only at a lookup, and connected panes do not look again, so it kept a
    /// replaced token and the helper refused every new chat until a pane reconnected. Chats already
    /// running keep the token their computer use server started with. Only a signed daemon this
    /// host owns and that runs: an attached daemon keeps its owner's endpoint, and an unsigned DEV
    /// daemon took its endpoint at spawn and refuses enrollment.
    public func computerUseChanged() async {
        if environment == nil { environment = resolveEnvironment() }
        guard startsDaemons, var environment, !environment.isAttached, !environment.passesPersonKeyAtSpawn else { return }
        // A lookup in flight enrolls the endpoint it read when it started: send the current one after it.
        for task in inFlight.values { _ = try? await task.value }
        guard FileManager.checked.fileExists(atPath: environment.socketPath) else { return }
        environment.computerUse = computerUse()
        await enrollComputerUse(environment)
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

    public func chatPeers() async throws -> [AgentChatPeer] {
        // Validate the app's daemon/home just as a composer handshake does. Listing never
        // starts another daemon; the tab store already prewarms its own host.
        // Waits for the lookup like a pane; a picker shows that the other Macs are not loaded yet
        // while it waits (AgentChatDestinations.updates), and the caller's cancel ends this wait.
        _ = try await endpoint(startsDaemon: false)
        guard let environment else { throw AgentPaneHostError.acpmuxNotFound }
        return try await AcpmuxStatusClient.chatPeers(socketPath: environment.socketPath)
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
        return await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner, daemons: daemons)
    }

    /// The person's "Restart agent service" while a pane waits for this host's daemon: only this
    /// app's own daemon (never an attached one, never the Chief home's), and only while a lookup
    /// waits on it, so the page cannot stop a daemon that answers. The lookup that waits ends when
    /// the daemon exits, and the page's next handshake starts a new one.
    public func restartStuckAcpmux(sessionId: String?) async -> Bool {
        guard startsDaemons, !inFlight.isEmpty else { return false }
        if environment == nil { environment = resolveEnvironment() }
        guard let environment, !environment.isAttached else { return false }
        return await daemonStop.restart(environment)
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
        // A lookup waits for a slow daemon's answer (``findOrStart(_:startsDaemon:owned:heal:startOwner:approver:)``):
        // every caller shares it, and each one may stop its own wait (its cancel) while the
        // lookup goes on for the others.
        if let task = inFlight[startsDaemon] { return try await AcpmuxSharedWait.value(of: task) }
        // A reconnect during a start waits for that daemon instead of
        // reporting it stopped.
        if !startsDaemon, let task = inFlight[true] { return try await AcpmuxSharedWait.value(of: task) }
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
        let (startOwner, approver, daemons) = (startOwner, peerApprover, daemons)
        let daemonReady = daemonReady
        // The lookup itself tells `daemonReady`, so a caller that stops waiting (its cancel) never
        // skips it for the others.
        let task = Task {
            let endpoint = try await Self.findOrStart(environment, daemons: daemons, startsDaemon: startsDaemon, owned: owned,
                                                      heal: heal, startOwner: startOwner, approver: approver)
            await daemonReady(daemonSocket)
            return endpoint
        }
        inFlight[startsDaemon] = task
        // The lookup leaves `inFlight` when it settles, not when this caller stops waiting: a
        // caller that cancels must not let the next one start a second lookup beside it.
        // task-owner: one per lookup; ends when the lookup settles
        Task { [weak self] in
            _ = await task.result
            await self?.settled(task, startsDaemon: startsDaemon)
        }
        return try await AcpmuxSharedWait.value(of: task)
    }

    private func settled(_ task: Task<AcpmuxWebEndpoint, any Error>, startsDaemon: Bool) {
        if inFlight[startsDaemon] == task { inFlight[startsDaemon] = nil }
    }

    /// Whether the enroll after a launch may hand the daemon off. Only a daemon this launch
    /// started: a launch that lost the lock race got the winner's readiness (`lockHeld`), and the
    /// winner is another client's daemon, which a handoff would shut down under that client and
    /// leave this one holding a dead endpoint. Such a daemon is enrolled like the one the
    /// exited-before-ready branch finds (`mayHandOff: false`).
    static func mayHandOff(after launched: AcpmuxDaemonLauncher.Launched) -> Bool {
        launched.startedHere
    }

    /// The pane's endpoint from `_acpmux/status` read on a connection whose server peer is the
    /// acpmux this app runs (cx-fcaq review P3-1): a squatter on the unix socket cannot point the
    /// pane at another daemon's WebSocket. It waits for the answer however long a loaded daemon
    /// takes (``findOrStart`` says why). Another cmux install's daemon (NIGHTLY shares
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
                                                             allowForeign: true, deadline: nil)
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
                              reason: "\(AgentPaneHostError.foreignHomeReason)\(status.home ?? ""), not \(environment.home.path)",
                              executable: environment.executable.path)
    }

    /// `_acpmux/status` of a daemon that just started, or won the start: waits up to 3 s while
    /// its socket is still being bound, as ``verifiedEndpoint(_:)`` does, then for its answer
    /// however long it takes. Nil when none answers.
    private static func startedStatus(_ environment: AcpmuxEnvironment) async -> AcpmuxStatus? {
        let deadline = ContinuousClock.now + .seconds(3)
        var delay: Duration = .milliseconds(100)
        // wakeup-allow: bounded retry while the started daemon binds its Unix socket; this exits at the deadline or on any other failure.
        while true {
            do {
                return try await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: nil)
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

    /// Finds this home's daemon, or starts one when none runs. A daemon is started again only
    /// when its process is gone: nothing listens on the socket and `daemon.pid` names no running
    /// process (``crashed(_:)``), or a handoff stopped it. A daemon that is slow to answer is not
    /// a dead one (rule R5: no timer decides correctness): under load (Austin, 2026-10-29, about
    /// 80 agents, load 150 to 252) acpmux answered after the 2 s status deadline, and stopping it
    /// then made every chat reload and the load worse. So the status calls here wait for the
    /// answer, and a daemon that exits closes the connection, which ends the wait; the pane shows
    /// that it is connecting meanwhile, and every pane that asks shares this one lookup.
    /// - Parameters:
    ///   - daemons: where a handoff or takeover marks the home restarting (Settings' daemon line).
    ///   - approver: gets this Mac's approver key to the daemon found or started; nil: none.
    private static func findOrStart(_ environment: AcpmuxEnvironment, daemons: AcpmuxLocalDaemons, startsDaemon: Bool, owned: Bool,
                                    heal: (@Sendable (Int32) async -> Bool)?,
                                    startOwner: (@Sendable () async -> Bool)? = nil,
                                    approver: AgentPanePeerApprover? = nil) async throws -> AcpmuxWebEndpoint {
        // cmux NEXT adopts its old acpmux home before it asks or starts a daemon (cx-is1kf.9).
        await AcpmuxEnvironment.adoptBuildHomes()
        // This lookup took a stray daemon over or handed a stale one off: Settings' daemon line
        // says restarting until it ends.
        var handedOff = false
        defer { if handedOff { daemons.mark(home: environment.home, restarting: false) } }
        do {
            let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: nil)
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
                    approver?.register(environment)
                }
                // A daemon that only runs an old version an update replaced: its owner
                // hands it off (its agents are adopted) and starts the bundled one. One that
                // stays (the handoff failed) still serves its chats: the peer check takes it as
                // another install's, so the pane shows them instead of a refusal.
                let replaced = status.pid.map(AcpmuxVersionHandoff.replaced(pid:)) == true
                if replaced, let pid = status.pid {
                    logger.info("acpmux \(pid) runs a replaced bundle's executable")
                    if let heal, await heal(pid) {
                        logger.info("acpmux \(pid) ran a replaced bundle; its owner restarts it")
                        throw AgentPaneHostError.daemonRestarting
                    }
                }
                do {
                    return try await Self.verifiedEndpoint(environment)
                } catch let refusal as AcpmuxServerPeer.Refusal {
                    // Only a refusal is a failure to reach acpmux; a replaced daemon that serves its chats is not.
                    if replaced, let pid = status.pid {
                        AcpmuxFailureLog(logPath: environment.logPath).record(.replacedBundle, detail: "pid \(pid): \(refusal)")
                    }
                    let reason = replaced ? AcpmuxFailureCause.replacedBundle.logText : nil
                    throw Self.refused(refusal, environment, reason: reason, startsDaemons: owned)
                }
            }
            // After an update, or for this launch's person key (`AcpmuxPersonKey`): a daemon
            // that cannot take the key is handed off and ours starts with it. A daemon no cmux
            // install runs (`~/.local/bin/acpmux`) is taken over first (`AcpmuxStrayDaemon`).
            let stray = await AcpmuxStrayDaemon.handOffIfStray(status, environment: environment, daemons: daemons)
            let stale = stray ? true : await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment, daemons: daemons)
            handedOff = stale
            let stopped = stale ? true : await AcpmuxPersonKey.enroll(status, environment: environment)
            guard stopped else {
                await AcpmuxComputerUse.enroll(environment)
                approver?.register(environment)
                return try await Self.verifiedEndpoint(environment)
            }
        } catch AcpmuxStatusClient.Failure.unreachable {
            logger.info("acpmux status unreachable socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
            // Nothing listens on the socket: start a daemon below, unless
            // the user stopped it. A reconnect starts one only after a crash
            // (cx-6bgzj); the new daemon adopts the agents still running.
            guard startsDaemon || owned && crashed(environment.home) else {
                // The Chief home's daemon: only its host starts it (cx-ebm.54). Ask the host, so a
                // restored Chief chat connects after a relaunch without Home being shown (#25570).
                if !owned, !environment.isAttached, let startOwner, await startOwner() {
                    throw AgentPaneHostError.chiefStarting
                }
                throw owned || environment.isAttached ? AgentPaneHostError.daemonStopped : AgentPaneHostError.chiefStopped
            }
        } catch AcpmuxStatusClient.Failure.noWebSocket {
            logger.error("acpmux status returned no websocket socket=\(environment.socketPath, privacy: .public)")
            throw failure(environment, .noWebSocket, detail: environment.socketPath)
        } catch let error as AgentPaneHostError {
            throw error
        } catch let refusal as AcpmuxServerPeer.Refusal {
            throw Self.refused(refusal, environment, startsDaemons: owned)
        } catch AcpmuxStatusClient.Failure.closed
            where crashed(environment.home) || AcpmuxServerPeer.socketPeer(socketPath: environment.socketPath) == nil {
            // The daemon exited while this lookup waited for its answer (the wait has no deadline,
            // so its close is how the wait ends): a crash leaves its daemon.pid, a SIGTERM removes it
            // and nothing listens on the socket then. The pane asks again, and that lookup starts one.
            logger.error("acpmux exited while a lookup waited socket=\(environment.socketPath, privacy: .public)")
            throw failure(environment, .exited, detail: "it exited while the app waited for its answer")
        } catch {
            logger.error("acpmux status failed error=\(String(describing: error), privacy: .public)")
            throw failure(environment, .other, detail: String(describing: error))
        }
        do {
            let launched = try await AcpmuxDaemonLauncher.launchReporting(environment)
            // A signed daemon ignores the spawn key: it takes the key by this app's signature.
            if let status = await Self.startedStatus(environment), status.serves(home: environment.home) {
                _ = await AcpmuxPersonKey.enroll(status, environment: environment,
                                                 mayHandOff: Self.mayHandOff(after: launched))
                await AcpmuxComputerUse.enroll(environment)
                approver?.register(environment)
            }
            return launched.endpoint
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
                approver?.register(environment)
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
