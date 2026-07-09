public import Foundation
import Observation

/// Queues terminal input until a panel's surface shell is ready.
///
/// Lifted one-for-one from the legacy `Workspace.sendInputWhenReady(_:to:)` plus
/// its `pendingTerminalInputObserversByPanelId` registry and the
/// `has`/`remove`/`removeAll` bookkeeping. The coordinator owns the registry of
/// pending one-shot registrations keyed by panel id; everything that touches the
/// app-target `TerminalPanel`, its surface, and `NotificationCenter`
/// (`.terminalSurfaceDidBecomeReady`) is reached through
/// ``PendingTerminalInputHosting`` so this type never holds the app-target
/// `Workspace` or its panels.
///
/// When asked to send input, it either sends immediately (surface already live)
/// or registers a one-shot surface-ready observer through the host and, for a
/// reason that carries a timeout, schedules a drop after the timeout. The fire
/// and timeout paths are idempotent: each guards on the registration still being
/// present before sending or logging, exactly as the legacy bodies did.
///
/// The timeout drop keeps the legacy `DispatchQueue.main.asyncAfter` verbatim:
/// this is a byte-faithful relocation, so the timer mechanism is preserved
/// rather than rewritten to an injected-`Clock` task. Replacing it is a separate
/// modernization, not part of this move.
@MainActor
@Observable
public final class PendingTerminalInputCoordinator {
    /// Per-panel list of queued surface-ready registrations.
    private var observersByPanelId: [UUID: [PendingTerminalInputObserver]] = [:]

    @ObservationIgnored
    private weak var host: (any PendingTerminalInputHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the queue drives the live panel/surface
    /// state through.
    public func attach(host: any PendingTerminalInputHosting) {
        self.host = host
    }

    /// Sends `text` to the terminal panel once its surface is ready, registering
    /// a one-shot not-ready observer (with a timeout drop) when it is not. Lifted
    /// from the legacy `Workspace.sendInputWhenReady(_:to:reason:)`. Touches the
    /// panel registry, the surface-ready observer, and the background-start
    /// request through ``PendingTerminalInputHosting``.
    public func sendInputWhenReady(
        _ text: String,
        toPanelId panelId: UUID,
        reason: WorkspacePendingTerminalInputReason = .configurationCommand
    ) {
        guard let host else { return }

        if host.pendingInputIsSurfaceReady(forPanelId: panelId) {
            host.pendingInputSendInput(text, toPanelId: panelId)
            return
        }

        let timeout = reason.timeout
        let registration = PendingTerminalInputObserver()

        registration.observer = host.pendingInputObserveSurfaceReady(forPanelId: panelId) { [weak self, registration] in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removeObserver(registration, forPanelId: panelId)
                self.host?.pendingInputSendInput(text, toPanelId: panelId)
            }
        }
        observersByPanelId[panelId, default: []].append(registration)
        host.pendingInputRequestBackgroundSurfaceStart(forPanelId: panelId)

        guard let timeout else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, registration] in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removeObserver(registration, forPanelId: panelId)
                #if DEBUG
                NSLog("[CmuxConfig] surface not ready after 3s, dropping command (%d chars)", text.count)
                #endif
            }
        }
    }

    /// Whether any surface-ready registration is still pending for a panel
    /// (legacy `pendingTerminalInputObserversByPanelId[panelId]?.isEmpty == false`).
    public func hasObservers(forPanelId panelId: UUID) -> Bool {
        observersByPanelId[panelId]?.isEmpty == false
    }

    /// Removes and unsubscribes every pending registration for a panel (legacy
    /// `removePendingTerminalInputObservers(forPanelId:)`).
    public func removeObservers(forPanelId panelId: UUID) {
        guard let observers = observersByPanelId.removeValue(forKey: panelId) else {
            return
        }
        for registration in observers {
            if let observer = registration.observer {
                NotificationCenter.default.removeObserver(observer)
                registration.observer = nil
            }
        }
    }

    /// Removes and unsubscribes pending registrations for every panel id absent
    /// from `validPanelIds` (legacy `pruneSurfaceMetadata` loop).
    public func removeObservers(forPanelIdsNotIn validPanelIds: Set<UUID>) {
        for panelId in Array(observersByPanelId.keys) where !validPanelIds.contains(panelId) {
            removeObservers(forPanelId: panelId)
        }
    }

    /// Unsubscribes every pending registration's notification observer without
    /// clearing the registry (legacy `Workspace` `deinit` teardown loop). Used
    /// when the owning workspace is being torn down.
    public func removeAllObserverTokens() {
        for registrations in observersByPanelId.values {
            for registration in registrations {
                if let observer = registration.observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
    }

    /// Drops every pending registration from the registry without unsubscribing
    /// its notification observer (legacy
    /// `pendingTerminalInputObserversByPanelId.removeAll(keepingCapacity: false)`
    /// in `clearPerPanelTeardownBookkeeping`). Preserves the legacy asymmetry: the
    /// teardown-bookkeeping clear drops the entries but does not call
    /// `removeObserver`.
    public func clearRegistry() {
        observersByPanelId.removeAll(keepingCapacity: false)
    }

    private func hasObserver(
        _ registration: PendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) -> Bool {
        observersByPanelId[panelId]?.contains {
            $0 === registration
        } == true
    }

    private func removeObserver(
        _ registration: PendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) {
        if let observer = registration.observer {
            NotificationCenter.default.removeObserver(observer)
            registration.observer = nil
        }
        observersByPanelId[panelId]?.removeAll {
            $0 === registration
        }
        if observersByPanelId[panelId]?.isEmpty == true {
            observersByPanelId.removeValue(forKey: panelId)
        }
    }
}
