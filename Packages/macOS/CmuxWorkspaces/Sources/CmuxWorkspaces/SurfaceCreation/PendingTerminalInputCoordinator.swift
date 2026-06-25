public import Foundation

/// Queues terminal input until a panel's shell surface is ready, then sends it.
///
/// Faithful lift of the `Workspace` pending-terminal-input subsystem: the
/// fast-path send when the surface is already live, the one-shot
/// `.terminalSurfaceDidBecomeReady` wait registered against the live surface, the
/// per-panel registry of pending registrations
/// (`pendingTerminalInputObserversByPanelId`), the timeout that drops queued
/// input that never became ready, and the per-panel teardown that cancels every
/// pending wait when a panel closes. The primitives that touch app-target live
/// state (the `TerminalPanel` registry lookup, the `panel.surface` readiness
/// probe, `panel.sendInput`, `requestBackgroundSurfaceStartIfNeeded`, and the
/// `NotificationCenter` observer keyed on the live surface) stay app-side behind
/// ``PendingTerminalInputHosting``; this coordinator never names one.
///
/// **Isolation design.** `@MainActor`, not an actor. Every legacy entry point
/// already ran on the main actor: `sendInputWhenReady` was called from the
/// custom-layout coordinator on main, the ready-notification observer hopped
/// back to `@MainActor` before mutating the registry, and the timeout closure
/// did the same. Co-locating the registry with its callers (the rule from stage
/// 3b: state lives where its callers live) turns every bridge into a plain call;
/// an actor here would manufacture an isolation domain the design immediately
/// re-enters. The host is held weakly: `Workspace` owns this coordinator, so a
/// strong back-reference would be a retain cycle.
///
/// **Per-call registration identity (preserved).** Each `sendInputWhenReady`
/// call gets its own ``Registration`` box, exactly as the legacy code created a
/// fresh `WorkspacePendingTerminalInputObserver` per call. A panel can have more
/// than one queued send in flight; all of their observers fire on the single
/// surface-ready notification, and each callback re-checks membership of its own
/// box (`===`), removes only that box, and sends only its own text. Binding the
/// callback and timeout to a specific box (not to "the first pending one")
/// reproduces the legacy per-call closure capture and keeps multiple concurrent
/// sends independent.
///
/// **Timeout as a Clock task, not `DispatchQueue.asyncAfter`.** The legacy drop
/// used `DispatchQueue.main.asyncAfter(deadline: .now() + timeout)`, banned by
/// `CLAUDE.md`. It becomes a `Task` that sleeps on an injected
/// `any Clock<Duration>` (production passes `ContinuousClock`; tests pass a
/// manual clock). The registry-membership guard makes a stale timeout fire a
/// no-op without a `Task.isCancelled` check, exactly as the legacy
/// `hasPendingTerminalInputObserver` guard did: if the registration was already
/// consumed by the ready notification (or torn down with its panel) the timeout
/// finds nothing to drop. `Clock.sleep` is the cancellable, testable replacement
/// for the banned `asyncAfter`.
@MainActor
public final class PendingTerminalInputCoordinator {
    /// A single queued send's registration, the package equivalent of the legacy
    /// private `WorkspacePendingTerminalInputObserver` box. It pairs the host's
    /// opaque surface-readiness observation with the per-call identity the
    /// callback and timeout guard on (`===`). Cancelling it removes the
    /// underlying `NotificationCenter` observer through the host handle.
    private final class Registration {
        var observation: (any PendingTerminalInputObservation)?

        init() {}

        func cancel() {
            observation?.cancel()
            observation = nil
        }
    }

    /// Clock backing the readiness-timeout sleeps. Injected so tests drive the
    /// drop cadence deterministically; production uses `ContinuousClock`.
    private let clock: any Clock<Duration>

    /// The app's DEBUG drop-trace sink, carrying the legacy
    /// `[CmuxConfig] surface not ready after 3s, dropping command (%d chars)`
    /// line the timeout `#if DEBUG` branch logged via `NSLog`. Kept app-side so
    /// the package never depends on the DEBUG-only log facility (no-op in
    /// release), matching the ``WorkspaceLayoutFollowUpCoordinator`` wiring. The
    /// `Int` is the dropped text's character count.
    private let debugLogDrop: @Sendable (Int) -> Void

    private weak var host: (any PendingTerminalInputHosting)?

    /// The pending one-shot readiness registrations, keyed by panel id. Legacy
    /// `Workspace.pendingTerminalInputObserversByPanelId`. A panel can have more
    /// than one queued send in flight (each `sendInputWhenReady` call appends one
    /// registration), so the value is an ordered array, matching the legacy
    /// `[UUID: [WorkspacePendingTerminalInputObserver]]`. An empty array is
    /// removed eagerly, exactly as the legacy `removeValue(forKey:)` cleanup did.
    private var pendingRegistrationsByPanelId: [UUID: [Registration]] = [:]

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    ///
    /// - Parameters:
    ///   - clock: the clock backing the readiness-timeout sleeps
    ///     (default `ContinuousClock`).
    ///   - debugLogDrop: the app's DEBUG drop-trace sink (default no-op; the app
    ///     passes its `NSLog` sink in DEBUG). The argument is the dropped text's
    ///     character count.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        debugLogDrop: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.clock = clock
        self.debugLogDrop = debugLogDrop
    }

    /// Wires the app-side host the queue drives through. Held weakly.
    public func attach(host: any PendingTerminalInputHosting) {
        self.host = host
    }

    /// Sends `text` to the panel identified by `panelId` once its surface is
    /// ready, registering a one-shot not-ready observation (with a timeout drop)
    /// when it is not yet ready. Legacy `Workspace.sendInputWhenReady(_:to:reason:)`.
    ///
    /// The fast path mirrors the legacy `if panel.surface.surface != nil` send.
    /// Otherwise the coordinator creates a ``Registration``, asks the host to
    /// register a `.terminalSurfaceDidBecomeReady` observation against the live
    /// surface, appends the registration to the per-panel registry, kicks a
    /// background surface start, and (when the reason carries a timeout) arms a
    /// Clock-backed drop. The readiness callback re-checks membership of its own
    /// registration, removes it, and asks the host to send; the timeout re-checks
    /// membership and drops.
    public func sendInputWhenReady(
        _ text: String,
        toPanelId panelId: UUID,
        reason: WorkspacePendingTerminalInputReason = .configurationCommand
    ) {
        guard let host else { return }

        if host.isTerminalSurfaceReady(forPanelId: panelId) {
            host.sendTerminalInput(text, toPanelId: panelId)
            return
        }

        let timeout = reason.timeout
        let registration = Registration()

        registration.observation = host.observeTerminalSurfaceReady(
            forPanelId: panelId,
            onReady: { [weak self, registration] in
                guard
                    let self,
                    self.hasPendingRegistration(registration, forPanelId: panelId)
                else {
                    return
                }
                self.removeRegistration(registration, forPanelId: panelId)
                self.host?.sendTerminalInput(text, toPanelId: panelId)
            }
        )
        pendingRegistrationsByPanelId[panelId, default: []].append(registration)
        host.requestBackgroundSurfaceStart(forPanelId: panelId)

        guard let timeout else { return }
        let timeoutSeconds = Duration.seconds(timeout)
        Task { [weak self, weak registration] in
            try? await self?.clock.sleep(for: timeoutSeconds)
            guard
                let self,
                let registration,
                self.hasPendingRegistration(registration, forPanelId: panelId)
            else {
                return
            }
            self.removeRegistration(registration, forPanelId: panelId)
            self.debugLogDrop(text.count)
        }
    }

    /// Cancels and removes every pending readiness registration for a closed
    /// panel. Legacy `Workspace.removePendingTerminalInputObservers(forPanelId:)`.
    public func removeObservations(forPanelId panelId: UUID) {
        guard let registrations = pendingRegistrationsByPanelId.removeValue(forKey: panelId) else {
            return
        }
        for registration in registrations {
            registration.cancel()
        }
    }

    /// Cancels and removes every pending registration whose panel id is not in
    /// `validPanelIds`. Legacy `Workspace.pruneSurfaceMetadata(validSurfaceIds:)`'s
    /// `for panelId in Array(…keys) where !validSurfaceIds.contains(panelId) {
    /// removePendingTerminalInputObservers(forPanelId:) }` loop.
    public func removeObservations(forPanelIdsNotIn validPanelIds: Set<UUID>) {
        // Snapshot the keys into an Array before iterating: removeObservations(forPanelId:)
        // calls removeValue(forKey:) on this same dictionary inside the loop, so iterating
        // the live Dictionary.Keys view would mutate the backing store during iteration
        // (exclusive-access / invalidated-iterator hazard). HEAD avoided this deliberately.
        for panelId in Array(pendingRegistrationsByPanelId.keys) where !validPanelIds.contains(panelId) {
            removeObservations(forPanelId: panelId)
        }
    }

    /// Whether the panel has any pending readiness registration, used to decide
    /// whether a background surface start has queued work. Legacy
    /// `Workspace.hasBackgroundSurfaceStartWork`'s
    /// `pendingTerminalInputObserversByPanelId[panel.id]?.isEmpty == false`.
    public func hasPendingObservations(forPanelId panelId: UUID) -> Bool {
        pendingRegistrationsByPanelId[panelId]?.isEmpty == false
    }

    /// Cancels and removes every pending registration across all panels. Legacy
    /// `Workspace`'s `isolated deinit` loop that walked
    /// `pendingTerminalInputObserversByPanelId.values` and removed each box's
    /// `NotificationCenter` observer.
    public func cancelAllObservations() {
        let all = pendingRegistrationsByPanelId.values.flatMap { $0 }
        pendingRegistrationsByPanelId.removeAll(keepingCapacity: false)
        for registration in all {
            registration.cancel()
        }
    }

    /// Drops the entire pending registry without removing the underlying
    /// `NotificationCenter` observers. Faithful lift of the legacy
    /// `Workspace.clearPerPanelTeardownBookkeeping`'s
    /// `pendingTerminalInputObserversByPanelId.removeAll(keepingCapacity: false)`,
    /// which discarded the boxes without calling `removeObserver` (the surfaces
    /// are being torn down in the same teardown turn). Prefer
    /// ``cancelAllObservations()`` when the observers must be released.
    public func clearAllObservationsWithoutCanceling() {
        pendingRegistrationsByPanelId.removeAll(keepingCapacity: false)
    }

    // MARK: - Registry bookkeeping

    /// Whether `registration` is still pending for the panel. Legacy
    /// `Workspace.hasPendingTerminalInputObserver(_:forPanelId:)`, an identity
    /// (`===`) membership test.
    private func hasPendingRegistration(
        _ registration: Registration,
        forPanelId panelId: UUID
    ) -> Bool {
        pendingRegistrationsByPanelId[panelId]?.contains { $0 === registration } == true
    }

    /// Cancels `registration`'s underlying observer and removes it from the
    /// per-panel list, dropping the panel key when its list empties. Legacy
    /// `Workspace.removePendingTerminalInputObserver(_:forPanelId:)`.
    private func removeRegistration(
        _ registration: Registration,
        forPanelId panelId: UUID
    ) {
        registration.cancel()
        pendingRegistrationsByPanelId[panelId]?.removeAll { $0 === registration }
        if pendingRegistrationsByPanelId[panelId]?.isEmpty == true {
            pendingRegistrationsByPanelId.removeValue(forKey: panelId)
        }
    }
}
