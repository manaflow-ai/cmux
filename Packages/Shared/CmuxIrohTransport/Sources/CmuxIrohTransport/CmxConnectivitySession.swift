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
    /// Whether one observed path remains inside the session's captured dial
    /// policy and provenance allowlist.
    func pathIsAllowed(_ path: CmxIrohObservedConnectionPath) -> Bool
    func observedPathEvents() async -> AsyncStream<CmxIrohConnectionPathEvent>
    func close() async
}

extension CmxConnectivitySession {
    /// Test/double compatibility for sessions that do not expose dial-plan
    /// provenance; production Iroh sessions override this at the owner seam.
    func pathIsAllowed(_: CmxIrohObservedConnectionPath) -> Bool { true }
}

extension CmxIrohClientSession: CmxConnectivitySession {}
