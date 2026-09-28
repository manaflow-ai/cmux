public import Foundation

/// Receive half of one carrier stream.
public protocol IrxCarrierRecvStream: Sendable {
    /// Up to `sizeLimit` bytes; an empty result means the peer finished.
    func read(sizeLimit: UInt32) async throws -> Data
    /// Tells the peer to stop sending, carrying `errorCode`.
    func stop(errorCode: UInt64) async throws
}
