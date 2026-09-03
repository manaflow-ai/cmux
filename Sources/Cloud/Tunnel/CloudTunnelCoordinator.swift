import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudTunnel")

/// Owns *when* this Mac's WireGuard tunnel into the Cloud VM network runs, on
/// builds where the app manages it (``CloudTunnelBackend/networkExtension``).
///
/// The policy, in one place:
///
/// - **Off until Cloud is used.** Nothing happens at launch. The first
///   private-network use (``prepareForPrivateNetworkUse(_:)``, reached through
///   every endpoint-minting ``VMClient`` call) enrolls this Mac, saves the VPN
///   configuration, and starts the tunnel. The caller waits a bounded
///   readiness budget so the dial that follows finds the route in place, then
///   proceeds either way.
/// - **Idle stop.** While up, an idle timer restarts on every Cloud use. When
///   it fires and no consumer is live (``CloudTunnelConsumerSource``), the
///   tunnel stops. `cmux vpn up` pins it until `cmux vpn down`.
/// - **Stops with the session.** Sign-out, revoke, and app termination stop it.
/// - macOS never auto-connects it: no NetworkExtension on-demand rules are set.
///
/// On the wg-quick backend every method is a no-op or a status read, so an
/// unentitled build behaves exactly as before this coordinator existed.
actor CloudTunnelCoordinator: CloudPrivateNetworkGate {
    let backend: CloudTunnelBackend
    private let controller: any CloudTunnelControlling
    private let enroller: any CloudTunnelEnrolling
    private let consumers: any CloudTunnelConsumerSource
    private let clock: any Clock<Duration>
    private let timing: CloudTunnelTiming

    private(set) var state: CloudTunnelState = .off
    private(set) var isPinned = false
    private var linkStatus: CloudTunnelLinkStatus = .disconnected
    private var startTask: Task<Void, any Error>?
    /// Bumped per start so a cancelled start that resumes late (activation
    /// approval is not cancellable) cannot clobber a newer start's state.
    private var startGeneration = 0
    private var idleTask: Task<Void, Never>?
    private var failureBackoffTask: Task<Void, Never>?
    /// True from a failed start until ``CloudTunnelTiming/failureBackoff`` elapses (or an explicit up/down).
    private(set) var isInFailureBackoff = false
    private var linkObservation: Task<Void, Never>?
    private let stateBroadcast = CloudTunnelBroadcast<CloudTunnelState>()
    private let linkBroadcast = CloudTunnelBroadcast<CloudTunnelLinkStatus>()

    init(
        backend: CloudTunnelBackend,
        controller: any CloudTunnelControlling,
        enroller: any CloudTunnelEnrolling,
        consumers: any CloudTunnelConsumerSource,
        clock: any Clock<Duration> = ContinuousClock(),
        timing: CloudTunnelTiming = CloudTunnelTiming()
    ) {
        self.backend = backend
        self.controller = controller
        self.enroller = enroller
        self.consumers = consumers
        self.clock = clock
        self.timing = timing
    }

    // MARK: - CloudPrivateNetworkGate

    func prepareForPrivateNetworkUse(_ use: CloudPrivateNetworkUse) async {
        guard backend.isNetworkExtension else { return }
        if state == .up {
            restartIdleTimer()
            return
        }
        if isInFailureBackoff {
            // The last start just failed; a burst of dials must not re-run
            // enrollment, activation, and the configuration save each time.
            logger.debug("Cloud use during the failure backoff; the dial proceeds without a retry")
            return
        }
        logger.info("Cloud use (\(use.purpose.rawValue, privacy: .public)) for \(use.machineID, privacy: .public): bringing the tunnel up")
        do {
            try await withDeadline(timing.readinessBudget) { try await self.ensureUp() }
            restartIdleTimer()
        } catch CloudTunnelError.deadlineExceeded {
            logger.notice("tunnel not up within the readiness budget; the dial proceeds without waiting")
        } catch is CancellationError {
            // The caller gave up on its endpoint (its request failed or was
            // cancelled); the start itself carries on for the next use.
        } catch {
            logger.error("tunnel start failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Explicit control (`cmux vpn up|down|revoke`, sign-out, quit)

    /// Start the tunnel and keep it up until ``requestDown()``. An explicit
    /// request always retries, backoff or not.
    func requestUp(pin: Bool) async throws {
        guard case .networkExtension = backend else {
            throw CloudTunnelError.backendUnavailable(backend.fallbackReason ?? .entitlementMissing)
        }
        if pin { isPinned = true }
        clearFailureBackoff()
        try await ensureUp()
    }

    /// Kick off a start without waiting for it; pair with ``waitForState``.
    func beginUp(pin: Bool) {
        guard backend.isNetworkExtension else { return }
        if pin { isPinned = true }
        clearFailureBackoff()
        _ = startTaskIfNeeded()
    }

    func requestDown() async {
        isPinned = false
        await tearDown()
    }

    /// The account signed out: nothing can use the network any more.
    func accessDidEnd() async {
        isPinned = false
        await tearDown()
    }

    /// Stop and delete the VPN configuration; the caller unenrolls server-side.
    func revoke() async throws {
        isPinned = false
        await tearDown()
        guard backend.isNetworkExtension else { return }
        try await controller.remove()
    }

    /// Best-effort synchronous stop from `applicationWillTerminate`.
    nonisolated func appWillTerminate() {
        guard backend.isNetworkExtension else { return }
        controller.stopForTermination()
    }

    func status() -> CloudTunnelStatus {
        CloudTunnelStatus(backend: backend, state: state, isPinned: isPinned)
    }

    /// The current state, then every change.
    func stateUpdates() -> AsyncStream<CloudTunnelState> {
        stateBroadcast.subscribe(current: state)
    }

    /// The first state satisfying `predicate`, or whatever the state is when
    /// `timeout` elapses.
    func waitForState(
        timeout: Duration,
        until predicate: @escaping @Sendable (CloudTunnelState) -> Bool
    ) async -> CloudTunnelState {
        if predicate(state) { return state }
        let updates = stateBroadcast.subscribe()
        do {
            return try await withDeadline(timeout) {
                for await candidate in updates where predicate(candidate) {
                    return candidate
                }
                return await self.state
            }
        } catch {
            return state
        }
    }

    // MARK: - Start

    /// Start if needed and wait for the outcome. Waits on the state stream
    /// rather than the start task's value so a caller's deadline can release
    /// it while the start itself carries on.
    private func ensureUp() async throws {
        if state == .up { return }
        _ = startTaskIfNeeded()
        let updates = stateBroadcast.subscribe(current: state)
        for await candidate in updates {
            switch candidate {
            case .up:
                return
            case .failed(let message):
                throw CloudTunnelError.startFailed(message)
            case .off:
                throw CloudTunnelError.startFailed(String(
                    localized: "cloudTunnel.error.startCancelled",
                    defaultValue: "The tunnel start was cancelled."
                ))
            case .starting, .awaitingApproval, .stopping:
                continue
            }
        }
        throw CancellationError()
    }

    private func startTaskIfNeeded() -> Task<Void, any Error> {
        if let startTask { return startTask }
        startGeneration += 1
        let generation = startGeneration
        // Visible before the task runs, so a subscriber never sees `.off`
        // between asking for the start and the start beginning.
        setState(.starting)
        observeLinkIfNeeded()
        let task = Task { try await self.performStart(generation: generation) }
        startTask = task
        return task
    }

    private func performStart(generation: Int) async throws {
        // Runs to completion on its own task, so clearing here (not in the
        // callers, which may be cancelled by their deadlines) is what keeps
        // "one start at a time" true. A superseded start owns nothing.
        defer {
            if startGeneration == generation { startTask = nil }
        }
        do {
            let enrollment = try await enroller.enroll()
            try Task.checkCancellation()
            let configuration = CloudTunnelProviderConfiguration(
                wgQuickConfig: enrollment.wgQuickConfig,
                serverAddress: enrollment.serverAddress,
                localizedDescription: String(localized: "cloudTunnel.vpnConfiguration.name", defaultValue: "cmux Cloud")
            )
            try await controller.install(configuration) { [weak self] in
                Task { await self?.noteAwaitingApproval(generation: generation) }
            }
            try Task.checkCancellation()
            if state == .awaitingApproval { setState(.starting, generation: generation) }
            // The extension outlives the app: after a crash or `kill`, the
            // tunnel can already be connected, and `startVPNTunnel` on a live
            // session posts no status change to wait for. Read the current
            // status and adopt a running tunnel instead of restarting it.
            let current = await controller.currentStatus()
            linkStatus = current
            switch current {
            case .connected:
                logger.notice("adopting a tunnel that is already connected")
            case .connecting, .reasserting:
                try await withDeadline(timing.connectTimeout) { try await self.waitForLink(.connected) }
            case .disconnected, .disconnecting, .invalid:
                try await controller.start()
                try await withDeadline(timing.connectTimeout) { try await self.waitForLink(.connected) }
            }
            setState(.up, generation: generation)
            restartIdleTimer()
            logger.notice("tunnel up")
        } catch is CancellationError {
            setState(.off, generation: generation)
            throw CancellationError()
        } catch {
            let message = Self.userMessage(for: error)
            setState(.failed(message), generation: generation)
            logger.error("tunnel start failed: \(message, privacy: .public)")
            // Leave nothing half-started behind a failure — unless a newer start
            // has taken over in the meantime; its tunnel is not ours to stop.
            if startGeneration == generation {
                beginFailureBackoff()
                try? await controller.stop()
            }
            throw (error as? CloudTunnelError) ?? CloudTunnelError.startFailed(message)
        }
    }

    private func noteAwaitingApproval(generation: Int) {
        guard startGeneration == generation, state == .starting else { return }
        logger.notice("waiting for the user to allow the tunnel extension in System Settings")
        setState(.awaitingApproval)
    }

    // MARK: - Failure backoff

    private func beginFailureBackoff() {
        failureBackoffTask?.cancel()
        isInFailureBackoff = true
        failureBackoffTask = Task { await self.runFailureBackoff() }
    }

    private func runFailureBackoff() async {
        do {
            try await clock.sleep(for: timing.failureBackoff)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        isInFailureBackoff = false
    }

    private func clearFailureBackoff() {
        failureBackoffTask?.cancel()
        failureBackoffTask = nil
        isInFailureBackoff = false
    }

    // MARK: - Stop

    private func tearDown() async {
        cancelIdleTimer()
        clearFailureBackoff()
        if let startTask {
            // Not awaited: a start blocked on the user's extension approval
            // cannot be interrupted, and the generation guard keeps its late
            // resumption from touching the state this stop sets.
            startTask.cancel()
            self.startTask = nil
            startGeneration += 1
        }
        if state == .off {
            // Nothing this instance started — but a tunnel the previous app
            // instance left connected (the extension outlives the app) is
            // still ours to take down on quit, sign-out, or `cmux vpn down`.
            let current = await controller.currentStatus()
            guard current == .connected || current == .connecting || current == .reasserting else { return }
            linkStatus = current
        }
        observeLinkIfNeeded()
        setState(.stopping)
        do {
            try await withDeadline(timing.stopTimeout) {
                try await self.controller.stop()
                try await self.waitForLink(.disconnected)
            }
        } catch {
            logger.error("tunnel stop did not complete cleanly: \(String(describing: error), privacy: .public)")
        }
        // A Cloud use that arrived mid-stop already owns the state (`.starting`).
        if startTask == nil {
            setState(.off)
        }
    }

    // MARK: - Idle policy

    private func restartIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
        guard state == .up, !isPinned else { return }
        idleTask = Task { await self.runIdleTimer() }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func runIdleTimer() async {
        do {
            try await clock.sleep(for: timing.idleGrace)
        } catch {
            return
        }
        guard !Task.isCancelled, state == .up else { return }
        let live = await consumers.liveConsumerCount()
        guard !Task.isCancelled, state == .up else { return }
        if live == 0 {
            logger.notice("no Cloud sessions remain; stopping the tunnel")
            await tearDown()
        } else {
            restartIdleTimer()
        }
    }

    // MARK: - Link status

    private func observeLinkIfNeeded() {
        guard linkObservation == nil else { return }
        let updates = controller.statusUpdates
        linkObservation = Task { [weak self] in
            for await status in updates {
                await self?.linkStatusDidChange(status)
            }
        }
    }

    private func linkStatusDidChange(_ status: CloudTunnelLinkStatus) {
        linkStatus = status
        linkBroadcast.yield(status)
        guard state == .up, status == .disconnected || status == .invalid else { return }
        // Stopped outside the app (System Settings, or the extension exited).
        logger.notice("tunnel went down outside the app; state is now off")
        cancelIdleTimer()
        setState(.off)
    }

    private func waitForLink(_ target: CloudTunnelLinkStatus) async throws {
        if linkStatus == target { return }
        let updates = linkBroadcast.subscribe()
        // NetworkExtension reports disconnected → connecting → connected (or
        // back to disconnected on failure). Saving the configuration can also
        // post a late `.disconnected` for the reloaded connection, so a drop
        // only counts as failure once this start has been seen connecting.
        var sawConnecting = false
        for await status in updates {
            if status == target { return }
            if target == .connected {
                if status == .connecting || status == .reasserting {
                    sawConnecting = true
                } else if sawConnecting, status == .disconnected || status == .invalid {
                    throw CloudTunnelError.startFailed(String(
                        localized: "cloudTunnel.error.linkDropped",
                        defaultValue: "macOS reported the VPN as disconnected before it came up."
                    ))
                }
            }
        }
        throw CloudTunnelError.startFailed(String(
            localized: "cloudTunnel.error.linkStatusUnavailable",
            defaultValue: "VPN status updates stopped arriving."
        ))
    }

    // MARK: - Helpers

    private func setState(_ newState: CloudTunnelState) {
        guard newState != state else { return }
        state = newState
        stateBroadcast.yield(newState)
    }

    /// `setState` for a start that may have been superseded by a stop or a
    /// newer start; a stale generation changes nothing.
    private func setState(_ newState: CloudTunnelState, generation: Int) {
        guard startGeneration == generation else { return }
        setState(newState)
    }

    /// Race `operation` against the clock; the loser is cancelled.
    private func withDeadline<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = self.clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: duration)
                throw CloudTunnelError.deadlineExceeded
            }
            guard let first = try await group.next() else {
                throw CloudTunnelError.deadlineExceeded
            }
            group.cancelAll()
            return first
        }
    }

    private static func userMessage(for error: any Error) -> String {
        if let tunnelError = error as? CloudTunnelError {
            return tunnelError.description
        }
        let nsError = error as NSError
        if nsError.domain == "NEVPNErrorDomain" || nsError.domain == "NEConfigurationErrorDomain" {
            let format = String(
                localized: "cloudTunnel.error.vpnConfiguration",
                defaultValue: "macOS rejected the VPN configuration (code %d)."
            )
            return String(format: format, nsError.code)
        }
        return nsError.localizedDescription
    }
}
