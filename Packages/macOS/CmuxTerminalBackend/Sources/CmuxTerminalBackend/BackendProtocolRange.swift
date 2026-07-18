/// A closed interval of backend protocol versions supported by one peer.
public struct BackendProtocolRange: Equatable, Sendable {
    /// The oldest supported protocol version.
    public let minimum: UInt32

    /// The newest supported protocol version.
    public let maximum: UInt32

    /// Creates a supported protocol interval.
    ///
    /// - Parameters:
    ///   - minimum: The oldest supported protocol version.
    ///   - maximum: The newest supported protocol version.
    public init(minimum: UInt32, maximum: UInt32) {
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Selects the newest protocol version supported by both peers.
    ///
    /// - Parameter peer: The other peer's supported protocol interval.
    /// - Returns: The negotiated version, or `nil` when the intervals do not overlap.
    public func negotiatedVersion(with peer: BackendProtocolRange) -> UInt32? {
        let lower = max(minimum, peer.minimum)
        let upper = min(maximum, peer.maximum)
        return lower <= upper ? upper : nil
    }
}
