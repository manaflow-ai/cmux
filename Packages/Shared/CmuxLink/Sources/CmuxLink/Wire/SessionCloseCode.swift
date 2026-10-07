/// The reason carried by a `sessionClose` frame.
public enum SessionCloseCode: UInt8, Sendable, Hashable {
    case normal = 0
    case unauthorized = 1
    case protocolViolation = 2
}
