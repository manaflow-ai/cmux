import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One-shot acknowledgement used by focus promotion to wait until the
/// foreground event listener exists locally and its server registration has
/// been acknowledged.
actor MobileTerminalEventSubscriptionReadiness {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }

    func hasSucceeded() -> Bool {
        result == true
    }
}

enum SecondaryMacPostDrainAction {
    case none
    case refreshPresence
    case retry
}

/// One physical close shared by every waiter on a retired control connection.
/// A timed-out Mac switch may retry the same reservation, but it must never
/// start another transport close or completion watcher for that peer.
@MainActor
final class SecondaryMacTransportDrainOperation {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    let task: Task<Void, Never>
    var completionTask: Task<Void, Never>?
    private var hasCompleted = false
    private var waiters: [UUID: Waiter] = [:]

    init(task: Task<Void, Never>) {
        self.task = task
    }

    var pendingWaiterCount: Int { waiters.count }

    func wait(nanoseconds: UInt64) async -> Bool {
        guard !hasCompleted else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !hasCompleted else {
                    continuation.resume(returning: true)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    self?.resolveWaiter(waiterID, value: false)
                }
                waiters[waiterID] = Waiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveWaiter(waiterID, value: false)
            }
        }
    }

    func finish() {
        guard !hasCompleted else { return }
        hasCompleted = true
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    private func resolveWaiter(_ waiterID: UUID, value: Bool) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: value)
    }
}

/// One non-focused Mac's persistent control connection plus its event consumer.
@MainActor
final class SecondaryMacSubscription {
    /// Control-plane topics intentionally exclude terminal render and byte traffic.
    static let eventTopics: Set<String> = [
        "workspace.updated",
        "notification.feed.changed",
    ]

    let macDeviceID: String
    let client: MobileCoreRPCClient
    /// The route and ticket this client was dialed on, kept for promotion.
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    /// Paired-row authority captured when this subscription was established.
    let storedInstanceTag: String?
    /// Instance identity proven by authenticated host status on this client.
    let authenticatedInstanceTag: String?
    /// Raw host capabilities reported by this secondary Mac.
    let supportedHostCapabilities: Set<String>
    /// Workspace action capabilities reported by this secondary Mac.
    let actionCapabilities: MobileWorkspaceActionCapabilities
    /// Human-readable Mac name for settings and diagnostics.
    let displayName: String?
    /// Per-connection stream id for the `mobile.events.subscribe` handshake.
    let streamID: String
    var task: Task<Void, Never>?
    /// Coalesces hot `workspace.updated` bursts to one leading and one trailing fetch.
    var refreshTask: Task<Void, Never>?
    /// Identifies the current per-Mac workspace refresh owner so an older task
    /// cannot clear a replacement after cancellation or role transition.
    var refreshOperationID: UUID?
    /// Coalescing pause between bounded leading/trailing refresh owners. A hot
    /// event stream gets periodic freshness without a tight request train.
    var deferredRefreshTask: Task<Void, Never>?
    var deferredRefreshOperationID: UUID?
    var refreshPending = false
    /// Increments for every workspace event, including events coalesced behind
    /// an in-flight refresh, so independent catch-up fetches cannot overwrite
    /// a newer event-driven result.
    var workspaceRefreshGeneration: UInt64 = 0
    /// Set before promotion waits on any RPC. Keepalive reassertions skip this
    /// subscription until it either becomes focused or promotion is abandoned.
    var isTransitioningToFocus = false
    /// Physical close finished for a non-public drain reservation. Completed
    /// reservations stay claimed until the active Mac switch either consumes
    /// them in its fresh-dial fallback or ends.
    var hasCompletedTransportDrain = false
    var transportDrainOperation: SecondaryMacTransportDrainOperation?
    /// Fresh connect attempts retain the drained target's pool slot until
    /// their replacement focus either publishes or fails.
    var transportDrainReservationHolders: Set<UUID> = []
    var postDrainAction: SecondaryMacPostDrainAction = .none
    /// Keepalive ticks skip a newly inserted subscription until its consumer's
    /// first server-side activation has completed.
    var hasActivatedControlStream = false
    /// Records an event consumer ending while promotion owns the subscription.
    /// If promotion is then abandoned before focus commits, the dead control
    /// connection is torn down instead of being returned to the pool.
    var eventStreamEndedDuringFocusTransition = false

    init(
        macDeviceID: String,
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        storedInstanceTag: String? = nil,
        authenticatedInstanceTag: String? = nil,
        supportedHostCapabilities: Set<String>,
        actionCapabilities: MobileWorkspaceActionCapabilities,
        displayName: String? = nil
    ) {
        self.macDeviceID = macDeviceID
        self.client = client
        self.route = route
        self.ticket = ticket
        self.storedInstanceTag = storedInstanceTag
        self.authenticatedInstanceTag = authenticatedInstanceTag
        self.supportedHostCapabilities = supportedHostCapabilities
        self.actionCapabilities = actionCapabilities
        self.displayName = displayName
        self.streamID = "ios-secondary-events-\(macDeviceID)-\(UUID().uuidString)"
    }

    func cancel() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshOperationID = nil
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        deferredRefreshOperationID = nil
        guard transportDrainOperation == nil else { return }
        let client = self.client
        Task { await client.disconnect() }
    }

    /// Stop the read-only consumer loops while keeping the client connected.
    func detachKeepingClient() {
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshOperationID = nil
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        deferredRefreshOperationID = nil
    }
}
