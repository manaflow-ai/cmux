import CMUXMobileCore
import Foundation

/// Internal admitted-session boundary owned only by one connectivity peer actor.
protocol CmxConnectivitySession: Sendable {
    func receiveControl(maximumByteCount: Int) async throws -> Data?
    func sendControl(_ data: Data) async throws
    func openBidirectionalLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream
    func serverEventByteStream() async throws -> CmxIndependentEventByteStream
    func waitUntilClosed() async
    func closeAttribution() async -> CmxIrohConnectionCloseAttribution
    func isClosed() async -> Bool
    func connectionContinuityID() async -> UInt64?
    func observedSelectedPath() async -> CmxIrohObservedConnectionPath
    func observedSelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath>
    func observedPathEvents() async -> AsyncStream<CmxIrohConnectionPathEvent>
    func close() async
}

extension CmxIrohClientSession: CmxConnectivitySession {}
