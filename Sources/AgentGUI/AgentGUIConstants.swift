import Foundation

enum AgentGUIConstants {
    static let observationCadence: TimeInterval = 2
    static let liveRecentActivityWindowMS = 10 * 60 * 1_000
    static let gateReevaluationCadence: TimeInterval = 60
    static let journalWatchCoalescing: Duration = .milliseconds(200)
    static let initialTailLineCap = 2_000
    static let journalWindowEntryCap = initialTailLineCap
    static let maxEntriesLimit = 200
}
