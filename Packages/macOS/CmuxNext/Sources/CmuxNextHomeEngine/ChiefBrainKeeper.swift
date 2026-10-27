public import CmuxNextDaemon
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
        if watch?.isStopped == true || !HomeBrainHost.canStart() { return false }
        let marker = home.shutdownMarker
        // concurrency-allow: one small stat per ask
        if FileManager.default.fileExists(atPath: marker.path) {
            guard asked else { return false }
            try? FileManager.default.removeItem(at: marker)
        }
        if starting || watch?.isWatching == true { return true }
        if let watch, let running = ChiefHostStop.runningHostPID(home: home) {
            watch.watch(running)
            return true
        }
        // A watch that gave up (a host that kept dying) is armed again by this ask. It is stopped
        // before it goes: a launch that printed no pid leaves its lock sources armed while
        // ``ChiefBrainWatch/isWatching`` is false, and a watch that is only dropped runs no cancel
        // handler, so those descriptors would live until the app quits, one pair per retry.
        watch?.stop()
        watch = nil
        start()
        return starting
    }

    /// A person's message in a conversation of the default Chief is an ask
    /// (cx-4io0o, hq-6d 2026-10-15): it starts the brain when none runs, also
    /// after `cmux chief shutdown`. The rule reads the owner's committed
    /// message, not the Home composer, so a send from Home, the `cmux` CLI or
    /// a page gets the same answer; the daemon starts every other Chief's
    /// brain on the same rule (cmux-tui chief_brains.rs `woken_by`).
    public func ask(after message: ConversationMessage, in summary: ConversationSummary?) {
        let mux = HomeChiefName.muxID
        guard message.author != mux, let summary, summary.participants.contains(where: { $0.id == mux }),
              summary.participants.first(where: { $0.id == message.author })?.kind == .human else { return }
        ensure(asked: true)
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
        if watch?.isStopped == true {
            if let pid, ChiefHostStop.isChiefHost(pid) { kill(pid, SIGTERM) }
            return
        }
        // Known gap: a launch whose pid the shell did not print, before the
        // host holds the lock, leaves nothing to watch until the next ask.
        if let watch {
            watch.watch(pid)
            return
        }
        let watch = ChiefBrainWatch(home: home, restart: { [weak self] in
            // The owner may have reconnected since: mint on the current connection.
            guard let self, let connection = connection() else { return nil }
            return await launch(host, connection: connection)
        }, watching: { [weak self] pid in self?.hostChanged?(pid) })
        self.watch = watch
        watch.watch(pid)
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
