import Foundation

/// One phase-less mouse-wheel delta delegated to the worker's timed touch drag.
public struct SimulatorScrollWheelEvent: Codable, Equatable, Sendable {
    /// Identity used to clear only this burst's conservative recovery state.
    public let id: UUID
    /// Raw normalized point where a new wheel burst begins.
    public let anchor: SimulatorPoint
    /// Raw normalized horizontal finger movement for this wheel event.
    public let deltaX: Double
    /// Raw normalized vertical finger movement for this wheel event.
    public let deltaY: Double

    /// Creates a normalized phase-less wheel event.
    public init(
        id: UUID = UUID(),
        anchor: SimulatorPoint,
        deltaX: Double,
        deltaY: Double
    ) {
        self.id = id
        self.anchor = anchor
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}
