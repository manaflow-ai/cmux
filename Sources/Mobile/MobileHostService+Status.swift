import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os


// MARK: - Status Snapshots & Event Fan-Out
extension MobileHostService {
    /// Fan out a server-pushed event to every connection subscribed to `topic`.
    /// Safe to call from any actor/queue.
    nonisolated func emitEvent(topic: String, payload: [String: Any]) {
        Self.emitEvent(topic: topic, payload: payload)
    }

    /// Static form for callers already on non-main queues or Sendable
    /// notification closures. This path only touches the connection registry,
    /// not actor-isolated listener state.
    nonisolated static func emitEvent(topic: String, payload: [String: Any]) {
        guard MobileHostEventSubscriptionTracker.hasSubscribers(topic: topic) else {
            return
        }
        let connections = MobileHostConnectionRegistry.shared.snapshot()
        guard !connections.isEmpty else { return }
        #if DEBUG
        cmuxDebugLog("mobile.emit topic=\(topic) connections=\(connections.count)")
        #endif
        for connection in connections {
            Task {
                let delivered = await connection.sendEvent(topic: topic, payload: payload)
                #if DEBUG
                cmuxDebugLog("mobile.emit -> connection delivered=\(delivered) topic=\(topic)")
                #endif
            }
        }
    }

    nonisolated static func hasEventSubscribers(topic: String) -> Bool {
        MobileHostEventSubscriptionTracker.hasSubscribers(topic: topic)
    }

    func statusSnapshot() -> MobileHostServiceStatus {
        let routes = listenerPort.map { routeResolver.routes(port: $0).routes } ?? []
        return makeStatus(routes: routes)
    }

    /// Emits the current ``MobileHostServiceStatus`` immediately, then a fresh
    /// snapshot every time the listener or active-connection set changes (driven by
    /// `.mobileHostStatusDidChange`). The in-app pairing window consumes this to flip
    /// from "waiting" to "connected" the instant a phone attaches; it is the same
    /// signal that backs the Mobile settings connection count. The stream ends when
    /// the consumer cancels its task.
    func statusUpdates() -> AsyncStream<MobileHostServiceStatus> {
        AsyncStream { continuation in
            // Bridge the notification through a Sendable `Void` signal so the
            // non-Sendable `Notification` never crosses into the MainActor drain.
            // Mirrors `HostSettingsActions.mobilePairingStatusUpdates()`.
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = MobileHostStatusObserverToken(
                NotificationCenter.default.addObserver(
                    forName: .mobileHostStatusDidChange,
                    object: nil,
                    queue: nil
                ) { _ in
                    signalContinuation.yield(())
                }
            )
            let drainTask = Task { @MainActor in
                continuation.yield(MobileHostService.shared.statusSnapshot())
                for await _ in signals {
                    if Task.isCancelled { break }
                    continuation.yield(MobileHostService.shared.statusSnapshot())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    /// Starts the pairing listener (if enabled and not already bound) and
    /// resolves once it can mint attach tickets, so the in-app pairing window
    /// can render a QR code without polling the listener state machine.
    ///
    /// Resolves immediately when the listener is already ready, or when pairing
    /// is disabled (the caller then renders an "off" state). Otherwise it awaits
    /// the next listener-state transition (`ready`, terminal `failed`, or
    /// `cancelled`) via a continuation, with a bounded safety deadline so the UI
    /// never hangs on a listener that never settles.
    func ensureListeningAndReady() async -> MobileHostServiceStatus {
        start()
        if listener == nil || listenerPort != nil {
            return statusSnapshot()
        }
        return await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
            if readinessTimeoutTask == nil {
                // Bounded, cancellable deadline: a local NWListener normally
                // reaches `.ready` within milliseconds; this only guards a
                // never-settling listener. Cancelled on the normal drain path.
                readinessTimeoutTask = Task { @MainActor [weak self] in
                    try? await ContinuousClock().sleep(for: .seconds(6))
                    guard let self, !Task.isCancelled else { return }
                    self.drainReadinessWaiters()
                }
            }
        }
    }

    /// Resumes every pending ``ensureListeningAndReady()`` caller with the
    /// current status and clears the bounded readiness deadline.
    func drainReadinessWaiters() {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        guard !readinessWaiters.isEmpty else { return }
        let snapshot = statusSnapshot()
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
    }

    private func makeStatus(routes: [CmxAttachRoute]) -> MobileHostServiceStatus {
        let isRunning = listener != nil && listenerPort != nil
        return MobileHostServiceStatus(
            isRunning: isRunning,
            port: listenerPort,
            configuredPort: Self.configuredPort(),
            // The actual bind outcome, not a recomputation from current defaults:
            // editing the preferred port before a restart must not flip this.
            usesEphemeralFallback: isRunning && listenerUsesEphemeralFallback,
            routes: routes,
            activeConnectionCount: MobileHostConnectionRegistry.shared.count,
            lastErrorDescription: lastErrorDescription
        )
    }

    func updatePublicStatusRoutes(
        port: Int,
        generation: UUID,
        tailscaleHosts: [String]
    ) {
        guard generation == listenerGeneration, listenerPort == port else {
            return
        }
        MobileHostPublicStatusCache.update(
            routes: routeResolver.routes(port: port, tailscaleHosts: tailscaleHosts).routes
        )
    }
}
