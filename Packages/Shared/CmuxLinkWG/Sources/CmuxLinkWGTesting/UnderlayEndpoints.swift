public import CmuxLinkWG

/// One case's underlays: a dialer, a listener, their fault hooks, and how
/// to stop them.
public struct UnderlayEndpoints: Sendable {
    public var dialer: any DatagramUnderlayDialer
    public var listener: any DatagramUnderlayListener
    public var faults: any UnderlayFaults
    public var stop: @Sendable () async -> Void

    public init(
        dialer: any DatagramUnderlayDialer,
        listener: any DatagramUnderlayListener,
        faults: any UnderlayFaults,
        stop: @escaping @Sendable () async -> Void = {}
    ) {
        self.dialer = dialer
        self.listener = listener
        self.faults = faults
        self.stop = stop
    }
}
