/// Arrival of one datagram at the viewer, by transport sequence number.
public struct RdArrival: Hashable, Sendable {
    public var transportSeq: UInt16
    /// Viewer monotonic microseconds (wraps; only differences matter).
    public var arrivalMicros: UInt32

    public init(transportSeq: UInt16, arrivalMicros: UInt32) {
        self.transportSeq = transportSeq
        self.arrivalMicros = arrivalMicros
    }
}
