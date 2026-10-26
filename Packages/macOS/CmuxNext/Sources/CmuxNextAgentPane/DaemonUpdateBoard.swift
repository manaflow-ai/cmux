public import Observation

/// The latest update state of each ``DaemonUpdateTarget``, as ``DaemonUpdatePolicy`` reports it:
/// the surfaces that show a machine (its sidebar tooltip, a notice of a failed update) read it.
@MainActor @Observable
public final class DaemonUpdateBoard {
    // lint:allow one board per app process: the policy writes it, the sidebar of every window reads it
    public static let shared = DaemonUpdateBoard()

    /// The latest event per target id.
    public private(set) var targets: [String: DaemonUpdateEvent] = [:]

    public init() {}

    public func apply(_ event: DaemonUpdateEvent) {
        guard event.state != .cleared else {
            targets[event.id] = nil
            return
        }
        targets[event.id] = event
    }
}
