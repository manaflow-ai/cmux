import Foundation

/// Answers "is anything still using the Cloud VM network?" for the idle
/// policy. The count is computed on demand rather than tracked through events
/// so a missed event can never strand the tunnel in either direction.
protocol CloudTunnelConsumerSource: Sendable {
    func liveConsumerCount() async -> Int
}

/// The app's consumers: workspaces bound to a Cloud machine (attached panes,
/// `cmux vm tui`/`ssh` terminals the app hosts) plus the headless cmux-tui
/// links that back the Machines tree and remote terminals.
