public import Foundation

/// One opaque frame on a lane. Carriers never parse `bytes`.
public struct TransportFrame: Sendable, Hashable {
    public var lane: TransportLane
    public var bytes: Data

    public init(lane: TransportLane, bytes: Data) {
        self.lane = lane
        self.bytes = bytes
    }
}
