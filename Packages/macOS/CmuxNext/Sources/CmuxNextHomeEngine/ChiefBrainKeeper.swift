public import CmuxNextDaemon
import CmuxNextHomeModel
import Darwin
public import Foundation
import os

/// Keeps this app's Chief brain host running while the app runs: it starts
/// the host (or finds the one that runs) and watches it, and when it dies
/// starts it again (`ChiefBrainWatch`), with Home open or not. Home opening,
/// the owner coming back after a stop, and the Settings engine panel ask
/// through `ensure()`, so no "open Home" step is ever needed. The home's
/// lock keeps one host per home, so a host another process started keeps
/// running with its token: no new token revokes its binding.
///
/// The answers are `chief_brain.keeper_*` in cmux-home-rules; this class reads what they need
/// (the marker's stat, the lock, the watch) and runs their effects in order.
@MainActor
public final class ChiefBrainKeeper {
    /// The Chief owner's connection, nil while it is not connected.
    public typealias Connection = @MainActor () -> DaemonConnection?
    /// Resolves the host for an owner connection (nil: this app runs no Chief).
    public typealias ResolveHost = @MainActor (DaemonConnection) async -> HomeBrainHost?
    /// Mints the mux's agent token on an owner connection.
    public typealias MintToken = @Sendable (DaemonConnection) async throws -> String
    /// The brain host this app watches started or died (its pid, nil: none).
    public typealias HostChanged = @MainActor (pid_t?) -> Void

    private let home: ChiefHome
    private let connection: Connection
    private let resolveHost: ResolveHost
    private let mint: MintToken
    private let hostChanged: HostChanged?
    /// A start is in flight.
    private var starting = false
    /// The watch of the host this app keeps. Readable inside the package so the replacement path
    /// below is under test: reaching it through a real start would run `HomeBrainHost.start`,
    /// which adopts this Mac's build homes and moves its acpmux.
    private(set) var watch: ChiefBrainWatch?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    /// - Parameter watch: the watch to start from, in place of the one a start would make. Only a
    ///   test passes one; the app always starts with none.
    public init(home: ChiefHome, connection: @escaping Connection, resolveHost: @escaping ResolveHost,
                mint: @escaping MintToken, hostChanged: HostChanged? = nil, watch: ChiefBrainWatch? = nil) {
        self.home = home
        self.connection = connection
        self.resolveHost = resolveHost
        self.mint = mint
        self.hostChanged = hostChanged
        self.watch = watch
    }

    /// Starts the brain when none runs and none is starting; whether a host
    /// is starting or watched afterwards. After `cmux chief shutdown` only an
    /// ask (`asked`: Home shown, an engine set) starts it again and takes
    /// the shutdown's marker away; the owner coming back or a panel's read
    /// does not.
    @discardableResult
    public func ensure(asked: Bool) -> Bool {
        let reply: KeeperEnsureReply? = try? HomeRules.chiefBrain("keeper_ensure", KeeperEnsureRequest(asked: asked, keeper: view()))
        return reply.map(run) ?? false
    }

    /// What the rules read of this keeper. The marker's stat and the lock read are made each time,
    /// where Swift made them only on the branch that needed them; both are small local reads.
    /// `needsCanStart`: false for an answer that does not read it (`keeper_is_running`), which skips
    /// the executable checks.
    private func view(needsCanStart: Bool = true) -> KeeperView {
        // concurrency-allow: one small stat per ask
        let marker = FileManager.default.fileExists(atPath: home.shutdownMarker.path)
        let canStart = needsCanStart && watch?.isStopped != true && HomeBrainHost.canStart()
        return KeeperView(canStart: canStart, shutdownMarker: marker,
                          starting: starting, hasWatch: watch != nil, watchStopped: watch?.isStopped == true,
                          watchWatching: watch?.isWatching == true, runningPid: ChiefHostStop.runningHostPID(home: home))
    }

    /// Runs an ensure answer's effects in order; whether a host is starting or watched afterwards.
    private func run(_ reply: KeeperEnsureReply) -> Bool {
        for effect in reply.effects {
            switch effect.kind {
            case "removeShutdownMarker":
                try? FileManager.default.removeItem(at: home.shutdownMarker)
            case "watch":
                if let pid = effect.pid { watch?.watch(pid) }
            case "dropWatch":
                // A watch that gave up (a host that kept dying) is armed again by this ask. It is
                // stopped before it goes: a launch that printed no pid leaves its lock sources armed
                // while ``ChiefBrainWatch/isWatching`` is false, and a watch that is only dropped runs
                // no cancel handler, so those descriptors would live until the app quits.
                watch?.stop()
                watch = nil
            case "start":
                start()
            default:
                logger.error("chief brain keeper: unknown effect \(effect.kind, privacy: .public)")
            }
        }
        switch reply.answer {
        case "yes": return true
        case "ifStarted": return starting
        default: return false
        }
    }

    /// The watch stopped restarting a host that kept dying (``ChiefBrainWatch/hasGivenUp``), until the next ask.
    public var hasGivenUp: Bool { watch?.hasGivenUp == true }

    /// Whether this home's brain host runs or is starting: one this app watches, or one
    /// another process started (it holds the home's lock).
    public var isRunning: Bool {
        let reply: KeeperRunningReply? = try? HomeRules.chiefBrain("keeper_is_running", KeeperRequest(keeper: view(needsCanStart: false)))
        return reply?.running ?? false
    }

    /// A Chief chat that found nothing on the Chief home's acpmux socket asks for the host
    /// (#25570): it starts one when none was started in this run, and says whether a host runs
    /// or is starting. A watch that gave up (a host that kept dying) is armed again only by an
    /// ask, never by a chat's retries, which would relaunch a crashing host every few seconds.
    public func ensureForChat() -> Bool {
        let reply: KeeperEnsureReply? = try? HomeRules.chiefBrain("keeper_ensure_for_chat", KeeperRequest(keeper: view()))
        return reply.map(run) ?? false
    }

    /// A person's message in a conversation of the default Chief is an ask
    /// (cx-4io0o, hq-6d 2026-10-15): it starts the brain when none runs, also
    /// after `cmux chief shutdown`. The rule reads the owner's committed
    /// message, not the Home composer, so a send from Home, the `cmux` CLI or
    /// a page gets the same answer; the daemon starts every other Chief's
    /// brain on the same rule (cmux-tui chief_brains.rs `woken_by`).
    public func ask(after message: ConversationMessage, in summary: ConversationSummary?) {
        let participants = summary?.participants.map { ChiefBrainParticipant(id: $0.id, kind: $0.kind.rawValue) }
        let request = KeeperAskRequest(author: message.author, participants: participants, keeper: view())
        guard let reply: KeeperAskReply = try? HomeRules.chiefBrain("keeper_ask", request),
              reply.asks, let ensure = reply.ensure else { return }
        _ = run(ensure)
    }

    /// Quit: the brain stops on purpose; it is not started again.
    public func stop() {
        let watch = watch ?? ChiefBrainWatch(home: home) { nil }
        watch.stop()
        self.watch = watch
    }

    private func start() {
        guard !starting, let connection = connection() else { return }
        starting = true
        // task-owner: reads the endpoint, then spawns the detached host once
        Task { [weak self] in
            guard let self else { return }
            // The start is over either way: a later ask may start again.
            defer { starting = false }
            guard let host = await resolveHost(connection) else { return }
            watchHost(host, pid: await launch(host, connection: connection))
        }
    }

    private func watchHost(_ host: HomeBrainHost, pid: pid_t?) {
        // Quit came while this start ran: the host must not outlive the quit.
        let stopped = watch?.isStopped == true
        let request = KeeperAfterStartRequest(
            pid: pid, hasWatch: watch != nil, watchStopped: stopped,
            pidIsHost: stopped && pid.map { ChiefHostStop.isChiefHost($0) || ChiefHostStop.isFilesHostLauncher($0) } == true)
        let after: KeeperAfterStart? = try? HomeRules.chiefBrain("keeper_after_start", request)
        switch after?.kind {
        case "terminate":
            if let pid = after?.pid { kill(pid, SIGTERM) }
            return
        case "createWatch":
            break
        case "watch":
            // Known gap: a launch whose pid the shell did not print, before the
            // host holds the lock, leaves nothing to watch until the next ask.
            watch?.watch(after?.pid)
            return
        default:
            return
        }
        let watch = ChiefBrainWatch(home: home, restart: { [weak self] in
            // The owner may have reconnected since: mint on the current connection.
            guard let self, let connection = connection() else { return nil }
            return await launch(host, connection: connection)
        }, watching: { [weak self] pid in self?.hostChanged?(pid) })
        self.watch = watch
        watch.watch(after?.pid)
    }

    private func launch(_ host: HomeBrainHost, connection: DaemonConnection) async -> pid_t? {
        let mint = mint
        do {
            let outcome = try await host.start { try await mint(connection) }
            logger.info("mux host: \(String(describing: outcome), privacy: .public)")
            return outcome.pid
        } catch {
            logger.error("mux agent token: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// `chief_brain::keeper::KeeperView`.
private nonisolated struct KeeperView: Encodable {
    var canStart: Bool
    var shutdownMarker: Bool
    var starting: Bool
    var hasWatch: Bool
    var watchStopped: Bool
    var watchWatching: Bool
    var runningPid: Int32?
}

private nonisolated struct KeeperRequest: Encodable {
    var keeper: KeeperView
}

private nonisolated struct KeeperEnsureRequest: Encodable {
    var asked: Bool
    var keeper: KeeperView
}

/// `chief_brain::keeper::EnsureReply`; effects flat, `kind` names the case.
private nonisolated struct KeeperEnsureReply: Decodable {
    nonisolated struct Effect: Decodable {
        var kind: String
        var pid: Int32?
    }

    var answer: String
    var effects: [Effect]
}

private nonisolated struct KeeperRunningReply: Decodable {
    var running: Bool
}

private nonisolated struct KeeperAskRequest: Encodable {
    var author: String
    var participants: [ChiefBrainParticipant]?
    var keeper: KeeperView
}

private nonisolated struct KeeperAskReply: Decodable {
    var asks: Bool
    var ensure: KeeperEnsureReply?
}

private nonisolated struct KeeperAfterStartRequest: Encodable {
    var pid: Int32?
    var hasWatch: Bool
    var watchStopped: Bool
    var pidIsHost: Bool
}

/// `chief_brain::keeper::AfterStart`, flat.
private nonisolated struct KeeperAfterStart: Decodable {
    var kind: String
    var pid: Int32?
}
