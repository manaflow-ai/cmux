public import Foundation

/// One delivered message: its revision in this channel direction (1, 2, ...
/// per epoch) and the payload.
public struct LinkMessage: Sendable, Hashable {
    public var revision: UInt64
    public var payload: Data

    public init(revision: UInt64, payload: Data) {
        self.revision = revision
        self.payload = payload
    }
}
