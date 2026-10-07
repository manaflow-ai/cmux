/// Shared by one session's services: closed when the device is revoked, so
/// no op runs and no input reaches a terminal after that point, even while
/// the revocation notices are still in flight.
public actor MobileSessionGate {
    public private(set) var isOpen = true

    public init() {}

    public func close() {
        isOpen = false
    }
}
