import CmuxTerminalSizing
import Foundation

/// A `disconnected-by` (or other non-network) detach that a view must show.
public struct TerminalSharingDetachment: Hashable, Sendable {
    /// Why the view was detached.
    public var reason: TerminalDetachReason
    /// When the host detached it.
    public var at: Date

    /// Creates a detachment record.
    ///
    /// - Parameters:
    ///   - reason: the detach reason.
    ///   - at: when it happened.
    public init(reason: TerminalDetachReason, at: Date) {
        self.reason = reason
        self.at = at
    }

    /// The actor, when a person disconnected the view.
    public var actor: TerminalDetachActor? {
        if case let .disconnectedBy(actor) = reason { return actor }
        return nil
    }
}
