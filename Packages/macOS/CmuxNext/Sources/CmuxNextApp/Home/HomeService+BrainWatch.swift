import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHomeEngine
import Darwin
import Foundation

extension HomeService {
    /// Starts the Chief home's brain host (or finds the one that runs) and
    /// watches it: when it dies, Home starts it again (`ChiefBrainWatch`),
    /// with Home open or not. Its lock keeps one host per home, so a host
    /// another build started keeps running with its token: no new token
    /// revokes its binding.
    func startBrainHost() {
        guard !startedBrainHost, let connection else { return }
        // While true, a start is in flight.
        startedBrainHost = true
        // task-owner: reads the endpoint, then spawns the detached host once
        Task { [weak self] in
            guard let self else { return }
            // The start is over either way: a later ask may start again.
            defer { startedBrainHost = false }
            guard let host = await brainHost(connection) else { return }
            watchBrain(host, pid: await start(host, connection: connection))
        }
    }

    /// Starts the brain when none runs and none is starting: Home opening,
    /// the owner coming back, Settings finding no brain (no "open Home" step).
    func ensureBrain() {
        if startedBrainHost || brainWatch?.isWatching == true || brainWatch?.isStopped == true { return }
        if let brainWatch, let running = ChiefHostStop.runningHostPID(home: chief.home) {
            brainWatch.watch(running)
            return
        }
        // A watch that gave up (a host that kept dying) is armed again by this ask.
        brainWatch = nil
        startBrainHost()
    }

    /// Quit: the brain stops on purpose; it is not started again.
    func stopBrainWatch() {
        let watch = brainWatch ?? ChiefBrainWatch(home: chief.home) { nil }
        watch.stop()
        brainWatch = watch
    }

    func watchBrain(_ host: HomeBrainHost, pid: pid_t?) {
        guard brainWatch == nil else {
            brainWatch?.watch(pid)
            return
        }
        let watch = ChiefBrainWatch(home: chief.home) { [weak self] in
            // The owner may have reconnected since: mint on the current connection.
            guard let self, let connection else { return nil }
            return await start(host, connection: connection)
        }
        brainWatch = watch
        watch.watch(pid)
    }

    private func brainHost(_ connection: DaemonConnection) async -> HomeBrainHost? {
        guard let socket = await connection.endpoint?.socketPath else { return nil }
        return HomeBrainHost.resolve(daemonSocket: socket, controlSocket: services.environment.launch.socketPath, home: chief.home)
    }

    /// The mux proves its principal with a token this (user) connection mints.
    private func start(_ host: HomeBrainHost, connection: DaemonConnection) async -> pid_t? {
        do {
            let outcome = try await host.start { try await ConversationClient(connection).agentToken(for: HomeService.mux.id) }
            logger.info("mux host: \(String(describing: outcome), privacy: .public)")
            return outcome.pid
        } catch {
            logger.error("mux agent token: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
