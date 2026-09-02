/// Keeps at most one resize request in flight and coalesces later samples.
public struct TuiManualIOResizeScheduler: Equatable, Sendable {
    /// The resize currently waiting for an acknowledgement.
    public private(set) var inFlight: TuiManualIOGrid?
    /// The newest sample received while a resize is in flight.
    public private(set) var pending: TuiManualIOGrid?
    /// The most recent acknowledged grid.
    public private(set) var lastDelivered: TuiManualIOGrid?

    /// Creates an empty scheduler.
    public init() {}

    /// Seeds the scheduler with the grid passed to a newly spawned relay.
    public mutating func seed(delivered grid: TuiManualIOGrid) {
        inFlight = nil
        pending = nil
        lastDelivered = grid
    }

    /// Clears all state after the relay dies.
    public mutating func reset() {
        inFlight = nil
        pending = nil
        lastDelivered = nil
    }

    /// Records a sample and returns it when it can be sent immediately.
    public mutating func sample(_ grid: TuiManualIOGrid) -> TuiManualIOGrid? {
        if let inFlight {
            pending = grid == inFlight ? nil : grid
            return nil
        }
        if grid == lastDelivered {
            pending = nil
            return nil
        }
        inFlight = grid
        return grid
    }

    /// Completes the current request and returns the next newest sample.
    public mutating func acknowledged() -> TuiManualIOGrid? {
        if let inFlight {
            lastDelivered = inFlight
        }
        inFlight = nil
        guard let next = pending, next != lastDelivered else {
            pending = nil
            return nil
        }
        pending = nil
        inFlight = next
        return next
    }
}
