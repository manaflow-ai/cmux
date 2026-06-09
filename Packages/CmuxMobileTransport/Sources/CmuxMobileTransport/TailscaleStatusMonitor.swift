import Foundation
@preconcurrency import Network
public import Observation
import os

/// An observable, push-driven view of ``TailscaleStatus`` for UI surfaces.
///
/// Re-evaluates the interface snapshot when `NWPathMonitor` reports a path
/// change (Tailscale toggling its tunnel up or down is a path change), and on
/// demand via ``refresh()``, which the root view calls when the app returns to
/// the foreground. There are no polling timers.
///
/// Construct one at the composition root and hand it to views (cmux injects it
/// through the `\.tailscaleStatusMonitor` SwiftUI environment key in
/// `CmuxMobileShellUI`). Inject a custom provider to drive tests.
@MainActor
@Observable
public final class TailscaleStatusMonitor {
    /// The most recently evaluated tailnet status.
    public private(set) var status: TailscaleStatus

    @ObservationIgnored private let provider: any NetworkInterfaceAddressProviding
    @ObservationIgnored private let pathMonitor: NWPathMonitor?
    /// Allocates monotonic tickets ordering every evaluation, including the
    /// ones taken off-main on the path-monitor queue.
    @ObservationIgnored private let ticketAllocator = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// The ticket of the last published evaluation; ``apply(_:ticket:)`` drops
    /// anything older so a slow path-queue walk cannot overwrite a fresher
    /// foreground `refresh()`.
    @ObservationIgnored private var lastAppliedTicket: UInt64 = 0

    /// Creates a monitor and synchronously evaluates the current status.
    ///
    /// - Parameters:
    ///   - provider: The interface-address source; defaults to the system
    ///     `getifaddrs` walk.
    ///   - monitorsPathChanges: Whether to arm an `NWPathMonitor` so status
    ///     re-evaluates on connectivity changes. Tests pass `false` to keep
    ///     evaluation fully deterministic.
    public init(
        provider: any NetworkInterfaceAddressProviding = SystemNetworkInterfaceAddressProvider(),
        monitorsPathChanges: Bool = true
    ) {
        self.provider = provider
        self.status = TailscaleStatus(interfaces: provider.currentInterfaceAddresses())
        guard monitorsPathChanges else {
            self.pathMonitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, provider] _ in
            // NWPathMonitor reports every path change (Wi-Fi, cellular, any
            // VPN), so walk the interfaces here on the monitor's utility
            // queue; only the publish hops to the main actor. Keeps the
            // syscall off the main thread during unrelated network churn.
            // Take the ordering ticket before walking so any refresh() that
            // starts later outranks this snapshot; apply(_:ticket:) then
            // drops it if a fresher evaluation already published.
            guard let self else { return }
            let ticket = self.nextEvaluationTicket()
            let next = TailscaleStatus(interfaces: provider.currentInterfaceAddresses())
            Task { @MainActor in self.apply(next, ticket: ticket) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.cmux.tailscale-status", qos: .utility))
    }

    /// Re-evaluates the tailnet status from a fresh interface snapshot.
    ///
    /// One bounded `getifaddrs` walk (microseconds, no I/O wait); kept
    /// synchronous so init and the app-foreground caller observe the result
    /// immediately instead of first painting a stale status.
    public func refresh() {
        let ticket = nextEvaluationTicket()
        apply(TailscaleStatus(interfaces: provider.currentInterfaceAddresses()), ticket: ticket)
    }

    /// Hands out the next evaluation ticket; callable from any context so the
    /// path-monitor queue and main-actor `refresh()` share one ordering.
    /// Internal (not private) so tests can stage out-of-order publishes.
    nonisolated func nextEvaluationTicket() -> UInt64 {
        ticketAllocator.withLock { counter in
            counter += 1
            return counter
        }
    }

    /// Publishes a newly evaluated status. Drops evaluations older than the
    /// last published one (a stale path-queue walk racing a foreground
    /// `refresh()`) and no-op updates, so SwiftUI observation is not
    /// invalidated by unrelated path churn. Internal (not private) so tests
    /// can stage out-of-order publishes.
    func apply(_ next: TailscaleStatus, ticket: UInt64) {
        guard ticket > lastAppliedTicket else { return }
        lastAppliedTicket = ticket
        if next != status {
            status = next
        }
    }

    deinit {
        pathMonitor?.cancel()
    }
}
