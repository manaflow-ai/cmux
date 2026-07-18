/// The admission result for one in-process transcript monitor.
nonisolated enum CodexTranscriptMonitorStartResult: Sendable, Equatable {
    case started(activeCount: Int)
    case replaced(activeCount: Int)
    case resourceExhausted(limit: Int)
}
