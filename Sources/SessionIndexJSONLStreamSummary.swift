struct SessionIndexJSONLStreamSummary: Sendable, Equatable {
    var bytesRead: Int = 0
    var linesVisited: Int = 0
    var stopReason: SessionIndexJSONLStreamStopReason = .completed
}
