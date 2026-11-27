import Observation

/// A read-only, observable view of this device's tailnet status with an
/// on-demand re-check: the UI-side port for the transport layer's system
/// detector.
///
/// Conformers publish ``status`` through Observation, so SwiftUI views that
/// read it re-render when the tailnet comes up or goes down. The app's
/// composition root adapts the concrete detector (which owns `NWPathMonitor`
/// and the interface walk) onto this protocol, keeping `CmuxMobileShellUI`
/// free of transport/infrastructure dependencies.
@MainActor
public protocol TailscaleStatusObserving: AnyObject, Observable, Sendable {
    /// The most recently evaluated tailnet status.
    var status: TailnetStatus { get }

    /// Re-evaluates the status from a fresh snapshot, for example when the
    /// app returns to the foreground after the user may have toggled
    /// Tailscale.
    func refresh()
}
