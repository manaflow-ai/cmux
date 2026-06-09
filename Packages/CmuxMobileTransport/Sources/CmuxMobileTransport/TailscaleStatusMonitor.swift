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
        monitor.pathUpdateHandler = { [weak self] _ in
            // The handler runs on the monitor queue; the snapshot itself is
            // re-read on the main actor so observation stays single-threaded.
            Task { @MainActor in self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.cmux.tailscale-status", qos: .utility))
    }

    /// Re-evaluates the tailnet status from a fresh interface snapshot.
    ///
    /// Cheap (one `getifaddrs` walk); call on app foreground or after a user
    /// action that may have toggled Tailscale.
    public func refresh() {
        let next = TailscaleStatus(interfaces: provider.currentInterfaceAddresses())
        if next != status {
            status = next
        }
    }

    deinit {
        pathMonitor?.cancel()
    }
}
