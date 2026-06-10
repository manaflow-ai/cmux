import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os


// MARK: - Listener Lifecycle
extension MobileHostService {
    /// Binds a candidate `NWListener` on `endpointPort` while the current listener
    /// keeps running, returning it (with `generation`) once it reaches `.ready`,
    /// or `nil` when the port is unavailable. A bounded, cancellable deadline
    /// guarantees the call can't hang; on timeout/failure the candidate is torn
    /// down and `nil` returned, leaving the live listener untouched.
    func bindReadyCandidate(on endpointPort: NWEndpoint.Port, generation: UUID) async -> (listener: NWListener, generation: UUID)? {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let candidate: NWListener
        do {
            candidate = try NWListener(using: NWParameters(tls: nil, tcp: tcpOptions), on: endpointPort)
        } catch {
            return nil
        }
        let queue = callbackQueue
        let didBind: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // One-shot resume guard + deadline holder (lock carve-out): the state
            // handler and the timeout race to resume the continuation exactly once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let timeoutHolder = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            let finish: @Sendable (Bool) -> Void = { ready in
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                guard !alreadyResumed else { return }
                timeoutHolder.withLock { task in
                    task?.cancel()
                    task = nil
                }
                continuation.resume(returning: ready)
            }
            candidate.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case let .waiting(error):
                    if Self.isAddressUnavailable(error) { finish(false) }
                default:
                    break
                }
            }
            // NWListener needs a newConnectionHandler set before `start()` or it
            // never reaches `.ready`; wiring the real accept path (with this
            // generation) also means no connection is dropped once it's adopted.
            candidate.newConnectionHandler = { connection in
                MobileHostRequestActivity.beginConnection()
                Self.acceptConnectionOffMain(connection, generation: generation)
            }
            candidate.start(queue: queue)
            // Bounded, cancellable safety deadline (check-timeout carve-out) so an
            // unclassified/stuck listener state can never hang the Apply flow.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(2))
                finish(false)
            }
            timeoutHolder.withLock { $0 = timeout }
        }
        guard didBind else {
            candidate.stateUpdateHandler = nil
            candidate.newConnectionHandler = nil
            candidate.cancel()
            return nil
        }
        return (candidate, generation)
    }

    /// Cuts over to a freshly-bound `candidate`: tears down the old listener and
    /// its connections (they reconnect on the new port), then adopts the candidate
    /// as the live listener, routes future state changes through the normal
    /// handler, and republishes routes.
    func adoptCandidateListener(_ candidate: NWListener, generation: UUID, port: Int) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        for connection in activeConnections.values {
            Task { await connection.close(reason: "pairing port changed") }
        }
        for connection in MobileHostConnectionRegistry.shared.removeAll() {
            Task { await connection.close(reason: "pairing port changed") }
        }
        activeConnections.removeAll()
        clientIDsByConnectionID.removeAll()

        listener = candidate
        listenerGeneration = generation
        listenerUsesEphemeralFallback = false
        listenerPort = port
        appliedPreferredPort = port
        lastErrorDescription = nil
        // The candidate is already `.ready`; route only *future* states normally.
        candidate.stateUpdateHandler = { state in
            Task { @MainActor in
                MobileHostService.shared.handleListenerState(state, generation: generation)
            }
        }
        routeResolver.refreshTailscaleRoutes(onResolvedHosts: { [weak self] hosts in
            Task { @MainActor [weak self] in
                self?.updatePublicStatusRoutes(port: port, generation: generation, tailscaleHosts: hosts)
            }
        })
        MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: port).routes)
        drainReadinessWaiters()
    }

    func start() {
        guard Self.isListeningEnabled else {
            #if DEBUG
            if Self.canPublishRoutesWithoutListenerForXCTest(defaults: .standard) {
                publishRoutesWithoutListenerForXCTest()
                return
            }
            #endif
            mobileHostLog.info("mobile host listener disabled; not binding")
            return
        }
        guard listener == nil else {
            return
        }

        startListener(usePreferredPort: true)
    }

    #if DEBUG
    nonisolated private static func canPublishRoutesWithoutListenerForXCTest(defaults: UserDefaults) -> Bool {
        guard isRunningUnderXCTest else { return false }
        return defaults.object(forKey: listeningEnabledDefaultsKey) == nil
    }

    private func publishRoutesWithoutListenerForXCTest() {
        guard listener == nil else { return }
        let port = Self.configuredPort()
        listenerGeneration = UUID()
        listenerUsesEphemeralFallback = false
        listenerPort = port
        appliedPreferredPort = port
        lastErrorDescription = nil
        MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: port).routes)
        mobileHostLog.info("mobile host listener disabled; publishing XCTest routes without binding")
    }
    #endif

    private func startListener(usePreferredPort: Bool) {
        let desiredPort = Self.configuredPort()
        appliedPreferredPort = desiredPort
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            let nextListener = try makeListener(
                parameters: parameters,
                usePreferredPort: usePreferredPort,
                port: desiredPort
            )
            let generation = UUID()
            listenerGeneration = generation
            nextListener.stateUpdateHandler = { state in
                Task { @MainActor in
                    MobileHostService.shared.handleListenerState(state, generation: generation)
                }
            }
            nextListener.newConnectionHandler = { connection in
                MobileHostRequestActivity.beginConnection()
                Self.acceptConnectionOffMain(connection, generation: generation)
            }
            listener = nextListener
            listenerUsesEphemeralFallback = !usePreferredPort
            listenerPort = nil
            nextListener.start(queue: callbackQueue)
        } catch {
            if usePreferredPort {
                mobileHostLog.info("mobile host preferred port unavailable before listener start, falling back to an ephemeral port")
                startListener(usePreferredPort: false)
                return
            }
            lastErrorDescription = String(describing: error)
            mobileHostLog.error("mobile host listener failed to start: \(String(describing: error), privacy: .public)")
            // No listener was registered, so no state callback will fire to drain
            // readiness waiters; resolve them now instead of waiting for the deadline.
            drainReadinessWaiters()
        }
    }

    private func makeListener(
        parameters: NWParameters,
        usePreferredPort: Bool,
        port: Int
    ) throws -> NWListener {
        if usePreferredPort,
           let rawPort = UInt16(exactly: port),
           let endpointPort = NWEndpoint.Port(rawValue: rawPort) {
            return try NWListener(using: parameters, on: endpointPort)
        }
        return try NWListener(using: parameters, on: .any)
    }

    func stop() {
        listenerGeneration = UUID()
        listenerUsesEphemeralFallback = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
        appliedPreferredPort = nil
        for connection in activeConnections.values {
            Task { await connection.close(reason: "service stopped") }
        }
        for connection in MobileHostConnectionRegistry.shared.removeAll() {
            Task { await connection.close(reason: "service stopped") }
        }
        activeConnections.removeAll()
        clientIDsByConnectionID.removeAll()
        MobileHostEventSubscriptionTracker.reset()
        MobileHostPublicStatusCache.update(routes: [])
        TerminalController.shared.clearAllMobileViewportReports(reason: "mobile.host.stopped")
        drainReadinessWaiters()
    }

    func restart() {
        stop()
        start()
    }

    func handleListenerState(_ state: NWListener.State, generation: UUID) {
        guard generation == listenerGeneration else {
            return
        }

        switch state {
        case .ready:
            listenerPort = listener?.port.map { Int($0.rawValue) }
            lastErrorDescription = nil
            if let listenerPort {
                routeResolver.refreshTailscaleRoutes(onResolvedHosts: { [weak self] hosts in
                    Task { @MainActor [weak self] in
                        self?.updatePublicStatusRoutes(
                            port: listenerPort,
                            generation: generation,
                            tailscaleHosts: hosts
                        )
                    }
                })
                MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: listenerPort).routes)
            } else {
                MobileHostPublicStatusCache.update(routes: [])
            }
            mobileHostLog.info("mobile host listener ready on port \(self.listenerPort ?? 0)")
            drainReadinessWaiters()
        case let .failed(error):
            handleListenerBindFailure(error: error, context: "failed after start")
        case .cancelled:
            listenerGeneration = UUID()
            listener = nil
            listenerUsesEphemeralFallback = false
            listenerPort = nil
            MobileHostPublicStatusCache.update(routes: [])
            drainReadinessWaiters()
        case let .waiting(error):
            // A preferred-port bind blocked by another listener surfaces as
            // `.waiting(.posix(.EADDRINUSE))` rather than `.failed`, and NWListener
            // would otherwise wait forever; treat address-unavailable the same as
            // a failure so the ephemeral fallback (and bound-port warning) fire.
            if Self.isAddressUnavailable(error) {
                handleListenerBindFailure(error: error, context: "in use (waiting)")
            } else {
                listenerPort = nil
                MobileHostPublicStatusCache.update(routes: [])
            }
        case .setup:
            listenerPort = nil
            MobileHostPublicStatusCache.update(routes: [])
        @unknown default:
            break
        }
    }

    /// Tears down a listener that could not bind its preferred port and, unless
    /// it was already on the ephemeral fallback, retries on an OS-assigned port.
    /// Shared by the `.failed` and `.waiting(addressUnavailable)` paths.
    private func handleListenerBindFailure(error: NWError, context: String) {
        lastErrorDescription = String(describing: error)
        MobileHostPublicStatusCache.update(routes: [])
        let shouldRetryWithEphemeralPort = !listenerUsesEphemeralFallback
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listenerGeneration = UUID()
        listener = nil
        listenerUsesEphemeralFallback = false
        listenerPort = nil
        if shouldRetryWithEphemeralPort {
            mobileHostLog.info("mobile host preferred port \(context, privacy: .public), falling back to an ephemeral port")
            startListener(usePreferredPort: false)
        } else {
            mobileHostLog.error("mobile host listener bind failed on ephemeral port: \(String(describing: error), privacy: .public)")
            // No retry left: unblock any readiness waiters (the retry path drains
            // them when the ephemeral listener reaches `.ready`).
            drainReadinessWaiters()
        }
    }

}
