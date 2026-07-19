internal import Foundation

/// One exact, locally bounded interaction-mode route for a canonical surface.
public struct BackendTerminalInteractionModeEventSubscription: Sendable {
    public let identifier: UUID
    public let events: AsyncStream<BackendTerminalInteractionModeChanged>

    public init(
        identifier: UUID,
        events: AsyncStream<BackendTerminalInteractionModeChanged>
    ) {
        self.identifier = identifier
        self.events = events
    }
}
