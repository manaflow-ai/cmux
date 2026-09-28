public import Foundation

/// Send half of one carrier stream.
public protocol IrxCarrierSendStream: Sendable {
    /// Writes all of `data`, returning once the carrier has accepted every byte.
    func writeAll(_ data: Data) async throws
    /// Ends the stream cleanly; the peer drains buffered bytes and then reads EOF.
    func finish() async throws
    /// Abandons the stream abruptly, carrying `errorCode` to the peer.
    func reset(errorCode: UInt64) async throws
    /// Hints relative scheduling priority to carriers that support it.
    func setPriority(_ priority: Int32) async throws
}
