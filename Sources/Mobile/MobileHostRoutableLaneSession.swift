import CMUXMobileCore
import CmuxIrohTransport

/// The two members the router needs from an admitted session. The legacy
/// server session conforms as-is; the next-transport bridge synthesizes a
/// conformer over its raw streams, and the router serves both identically.
/// The error contract carries over: `applicationLaneRejected` means one
/// stream was reset and the session lives, any other error is
/// connection-fatal, cancellation is a quiet exit.
protocol MobileHostRoutableLaneSession: Sendable {
    var peer: CmxIrohAdmittedPeer { get }
    func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    )
}

extension CmxIrohAdmittedServerSession: MobileHostRoutableLaneSession {}
