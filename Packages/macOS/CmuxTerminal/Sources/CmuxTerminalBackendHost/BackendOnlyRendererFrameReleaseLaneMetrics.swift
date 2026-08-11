struct BackendOnlyRendererFrameReleaseLaneMetrics: Equatable, Sendable {
    var workerStarts: UInt64 = 0
    var sent: UInt64 = 0
    var outstanding: Int = 0
    var maximumOutstanding: Int = 0
    var capacityFailures: UInt64 = 0
    var sendFailures: UInt64 = 0
    var rejectedAfterStop: UInt64 = 0
}
