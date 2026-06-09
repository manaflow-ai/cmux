import Foundation
@preconcurrency import Network
public import Observation

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
            let next = TailscaleStatus(interfaces: provider.currentInterfaceAddresses())
            Task { @MainActor in self?.apply(next) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.cmux.tailscale-status", qos: .utility))
    }

    /// Re-evaluates the tailnet status from a fresh interface snapshot.
    ///
    /// One bounded `getifaddrs` walk (microseconds, no I/O wait); kept
    /// synchronous so init and the app-foreground caller observe the result
    /// immediately instead of first painting a stale status.
    public func refresh() {
        apply(TailscaleStatus(interfaces: provider.currentInterfaceAddresses()))
    }

    /// Publishes a newly evaluated status, dropping no-op updates so SwiftUI
    /// observation is not invalidated by unrelated path churn.
    private func apply(_ next: TailscaleStatus) {
        if next != status {
            status = next
        }
    }

    deinit {
        pathMonitor?.cancel()
    }
}
