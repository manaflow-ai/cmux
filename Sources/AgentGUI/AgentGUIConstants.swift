import Foundation

enum AgentGUIConstants {
    static let observationCadence: TimeInterval = 2
    static let liveRecentActivityWindowMS = 10 * 60 * 1_000
    static let gateReevaluationCadence: TimeInterval = 60
    static let journalWatchCoalescing: Duration = .milliseconds(200)
    static let initialTailLineCap = 2_000
    static let initialTailByteCap = 4 * 1_024 * 1_024
    static let journalIncrementalByteCap = initialTailByteCap
    static let journalPageByteCap = 4 * 1_024 * 1_024
    static let journalPageRawLineMultiplier = 4
    static let journalPageContextLineCap = 256
    static let journalPageContextByteCap = 1 * 1_024 * 1_024
    static let journalToolCallCacheCap = 512
    static let journalWindowEntryCap = initialTailLineCap
    static let maxEntriesLimit = 200
    static let sendTicketIdempotencyWindowMS = 300 * 1_000
    static let resolvedSendTicketRetentionLimit = 256
    static let sendEchoTimeoutMS = 120 * 1_000
    static let sendEchoUnmatchedAppendLimit = 3
    static let askTimeoutMS = 120 * 1_000
}
