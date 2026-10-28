import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextWakeups

/// Connects permissioned native provider demand to already admitted machine watches.
///
/// Registry changes drive admission. Every notice is fenced by the original
/// connection stamp, route epoch, canonical owner and native lease. Only an
/// empty invalidation is sent back; this bridge never starts owners or jobs.
///
/// The registry follow is a ``ServiceObservation`` in the automation class (p06-scheduler.md rule 3): its apply
/// admits and retires daemon watches for agents' inventory reads, and must run while no window shows. A burst of
/// registry changes reconciles once, as one posted task (Chromium's classed UI-thread task, base/task/task_traits.h).
@MainActor
public final class AgentInventoryProviderBridge {
    private let routes: @MainActor @Sendable () -> [AgentInventoryWatchRoute]
    private let work: MainWorkScheduler
    private var following: ServiceObservation<[AgentInventoryWatchRoute]>?
    private var provider: AppProviderSession?
    private var demand: AgentInventoryProviderDemand?
    private var registered = false
    private(set) var slots: [AgentInventoryWatchSlot] = []
    private var notifying: Task<Void, Never>?
    private var dirty = false
    private var disabled = false
    private var retiring: Task<Void, Never>?

    /// Creates the bridge over the registry's observable admitted-ready projection.
    /// - Parameters:
    ///   - work: The app's one main-thread scheduler; the registry follow flushes on it.
    ///   - routes: Reads policy, membership, ready connection and route epoch.
    public init(on work: MainWorkScheduler, routes: @escaping @MainActor @Sendable () -> [AgentInventoryWatchRoute]) {
        self.work = work
        self.routes = routes
    }

    /// Starts event-driven registry observation and reconciles the current routes before it returns; repeated calls
    /// are harmless.
    public func start() {
        guard following == nil else { return }
        following = ServiceObservation(.automation, owner: "AgentInventoryProviderBridge.routes", on: work, read: routes) { [weak self] _ in
            self?.reconcile()
        }
    }

    /// Stops observation and invalidates callbacks before retiring leases.
    public func stop() { following?.cancel(); following = nil; reset() }

    /// Begins one captured registration, retaining demand events that precede its reply.
    /// - Parameter session: The actual ready transport used for registration.
    public func begin(_ session: AppProviderSession) {
        reset(); provider = session
    }

    /// Completes registration; a newer event wins over an older reply snapshot.
    /// - Parameters:
    ///   - session: The same captured registration carrier.
    ///   - snapshot: Exact native demand, nil when the owner is legacy.
    public func registered(_ session: AppProviderSession, snapshot: AgentInventoryProviderDemand?) {
        guard provider === session, !Task.isCancelled else { return }
        guard let snapshot else { reset(); return }
        registered = true
        accept(snapshot)
        reconcile()
    }

    /// Rejects only the registration attempt that still owns this bridge.
    /// - Parameter session: The failed captured registration, if one was obtained.
    public func rejected(_ session: AppProviderSession?) {
        if let session, provider === session { reset() }
    }

    /// Receives original side events; stale or unkeyed sources cannot change demand.
    /// - Parameter envelope: An unchanged store fanout envelope.
    public func handle(_ envelope: DaemonEventEnvelope) {
        guard let provider, provider.matches(envelope), let next = AgentInventoryProviderDemand(envelope.event) else { return }
        accept(next)
        reconcile()
    }

    /// Changes app policy, invalidating callbacks immediately when disabled.
    /// - Parameter disabled: Whether app operations are currently turned off.
    public func setDisabled(_ disabled: Bool) {
        self.disabled = disabled
        if disabled { notifying?.cancel(); notifying = nil; dirty = false }
        reconcile()
    }

    /// Retires this provider generation without redirecting any cleanup to a replacement.
    public func reset() {
        provider = nil; registered = false; demand = nil
        notifying?.cancel(); notifying = nil; dirty = false
        for slot in slots { retire(slot) }
        slots.removeAll()
    }

    private func accept(_ next: AgentInventoryProviderDemand) {
        if let demand, next.sequence <= demand.sequence { return }
        demand = next
        slots.removeAll { $0.retired }
        notifying?.cancel(); notifying = nil; dirty = false
    }

    /// Re-evaluates actual registry admission rather than relying on observation delivery order.
    func reconcile() {
        let admitted = routes()
        let unique = admitted.filter { route in
            route.controlStamp != nil && admitted.filter { $0.machine == route.machine || $0.connection === route.connection }.count == 1
        }
        let wanted = registered && demand?.enabled == true && !disabled ? unique : []
        let removed = slots.filter { slot in !wanted.contains(slot.route) }
        for slot in removed { retire(slot) }
        slots.removeAll { slot in removed.contains(where: { $0 === slot }) }
        for route in wanted where !slots.contains(where: { $0.route == route }) {
            let slot = AgentInventoryWatchSlot(route: route)
            slots.append(slot)
            let retirement = retiring
            // task-owner: one bounded native admission; route, demand or policy retirement cancels it.
            // main-hop-allow: the admission re-checks the main-actor slot and registry (current) after each await, and
            // the carrier's capture and enable run on the connection's actor and the watch's actor, off main
            slot.admission = Task { [weak self, weak slot] in
                guard let self, let slot else { return }
                await retirement?.value
                guard current(slot), !Task.isCancelled else { return }
                do {
                    let carrier = try await AgentInventoryWatchCarrier(connection: route.connection, expectedMachineID: route.machine)
                    guard current(slot), !Task.isCancelled else { retire(slot); return }
                    guard carrier.sourceID == route.controlStamp?.sourceID, carrier.serial == route.controlStamp?.serial else { return }
                    slot.carrier = carrier
                    slot.token = route.events.subscribeEnvelopes { [weak self, weak slot] envelope in
                        // The cheap carrier match first: current(slot) rebuilds every registry route.
                        guard carrier.matches(envelope), let self, let slot, current(slot),
                              let notice = AgentInventoryWatchEvent(envelope.event) else { return }
                        if slot.receipt == nil {
                            guard slot.early.count < 32 else { retire(slot); return }
                            slot.early.append(notice)
                        } else { receive(notice, slot: slot) }
                    }
                    let receipt = try await carrier.watch.enable()
                    guard current(slot), !Task.isCancelled else { retire(slot); return }
                    slot.receipt = receipt
                    let early = slot.early; slot.early.removeAll()
                    for notice in early { receive(notice, slot: slot) }
                    if !slot.retired { invalidate() }
                } catch {
                    // Keep the failed generation fenced until route or demand admission changes.
                    if let token = slot.token { route.events.unsubscribe(token); slot.token = nil }
                }
            }
        }
    }

    private func current(_ slot: AgentInventoryWatchSlot) -> Bool {
        registered && demand?.enabled == true && !disabled && !slot.retired
            && slots.contains(where: { $0 === slot }) && routes().contains(slot.route)
            && slot.route.events.controlStamp == slot.route.controlStamp
    }

    private func receive(_ notice: AgentInventoryWatchEvent, slot: AgentInventoryWatchSlot) {
        guard current(slot), let receipt = slot.receipt else { return }
        switch notice {
        case .changed(let changed):
            guard changed.machine == receipt.machine, changed.watchID == receipt.watchID, changed.revision > receipt.revision else { return }
            slot.receipt = changed
            invalidate()
        case .ended(let machine, let watchID, _):
            guard machine == receipt.machine, watchID == receipt.watchID else { return }
            retire(slot)
            // No automatic re-admission on an ended lease. A new route or demand generation must admit it.
        }
    }

    /// A replacement cannot share an old live receipt before its conditional retirement starts.
    private func retire(_ slot: AgentInventoryWatchSlot) {
        guard let cleanup = slot.retire() else { return }
        let prior = retiring
        // task-owner: receipt retirement barrier survives provider replacement and gates new enables.
        // Off main: it only awaits the earlier barrier and this slot's cleanup.
        retiring = Task { @concurrent in await prior?.value; await cleanup.value }
    }

    private func invalidate() {
        guard registered, !disabled, let provider, let demand, demand.enabled else { return }
        dirty = true
        guard notifying == nil else { return }
        // task-owner: one coalesced bounded invalidation, cancelled on provider, demand or policy changes.
        // main-hop-allow: the loop reads the main-actor dirty flag and slots between sends; each invalidate awaits the
        // provider session's daemon request, off main
        notifying = Task { [weak self] in
            while let self, !Task.isCancelled, self.provider === provider, self.demand == demand,
                  registered, !disabled, dirty, slots.contains(where: { current($0) && $0.receipt != nil }) {
                dirty = false
                do { try await provider.invalidate(sequence: demand.sequence) }
                catch { break }
            }
            guard let self, self.provider === provider, self.demand == demand else { return }
            notifying = nil
        }
    }
}
