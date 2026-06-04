internal import CmuxMobileTransport
import Observation

/// The network-recovery state machine carved out of ``MobileShellComposite``.
///
/// Subscribes to the injected ``ReachabilityProviding`` path-change stream
/// and funnels every trigger (network change, manual Retry) through one
/// guarded recovery entry: a live connection only resyncs its event stream,
/// a dropped connection reconnects once, and a failed reconnect surfaces the
/// manual Retry control via ``connectionRecoveryFailed``. The single
/// `recoveryInFlight` flag (not a task generation) is kept verbatim from the
/// composite: overlapping triggers must coalesce into the in-flight attempt,
/// and the next path change after a failure retries automatically.
@MainActor
@Observable
final class MobileRecoveryCoordinator {
    /// True while an automatic reconnect is in progress after a network change
    /// or drop.
    var isRecoveringConnection: Bool = false
    /// True when automatic recovery could not restore the connection; the UI
    /// surfaces a manual Retry control in this state.
    var connectionRecoveryFailed: Bool = false

    private let reachability: any ReachabilityProviding
    /// The facade providing connection state. Weak: the facade owns this
    /// coordinator strongly, so this back-edge must not retain it.
    private weak var context: (any MobileConnectionRecoveryContext)?

    private var networkPathObservationStarted = false
    private var networkPathObservationTask: Task<Void, Never>?
    private var recoveryInFlight = false
    private var recoveryTask: Task<Void, Never>?
    private var lastReconnectStackUserID: String?

    private enum RecoveryTrigger: CustomStringConvertible {
        case networkChange
        case manual
        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            }
        }
    }

    init(reachability: any ReachabilityProviding) {
        self.reachability = reachability
    }

    isolated deinit {
        networkPathObservationTask?.cancel()
    }

    /// Attach the facade after both objects exist. Called once from
    /// ``MobileShellComposite/init``.
    func bind(context: any MobileConnectionRecoveryContext) {
        self.context = context
    }

    /// Records the Stack user a later automatic recovery should reconnect as,
    /// and arms path-change observation. Called at the top of every
    /// reconnect-on-launch attempt.
    func prepareForReconnect(stackUserID: String?) {
        lastReconnectStackUserID = stackUserID
        startObservingNetworkPathChanges()
    }

    /// Begin observing meaningful network path changes (Wi-Fi<->cellular,
    /// offline->online) so a live terminal recovers when the network moves out
    /// from under it. Idempotent; only the first call arms the observation.
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        let reachability = reachability
        networkPathObservationTask = Task { @MainActor [weak self] in
            // Each yield marks a meaningful path change (offline->online or a
            // primary-interface switch while online); recover the live
            // connection so a moving network repaints instead of going stale.
            for await _ in reachability.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// User-initiated reconnect from the Retry control.
    func retryMobileConnection() {
        connectionRecoveryFailed = false
        recoverMobileConnection(trigger: .manual)
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). When still connected, a network move usually only broke the event
    /// stream while input keeps flowing over the surviving connection, so a
    /// resync re-subscribes and requests a render-grid replay to repaint.
    /// Otherwise the connection dropped, so reconnect once; on failure the UI
    /// shows Retry and the next network change re-attempts automatically.
    private func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard let context, context.canAttemptRecovery else { return }
        if context.hasLiveRemoteConnection {
            context.markMacConnectionReconnecting()
            context.resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            return
        }
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            defer {
                self?.recoveryInFlight = false
                self?.isRecoveringConnection = false
            }
            guard let self, self.context?.isConnected == false else { return }
            let reconnected = await self.context?.reconnectActiveMacIfAvailable(stackUserID: stackUserID) ?? false
            if !reconnected, !Task.isCancelled {
                self.connectionRecoveryFailed = true
            }
        }
    }
}
