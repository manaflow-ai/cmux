import Foundation

struct MobileDebugLogSinkEntry: Sendable {
    let issuedAt: ContinuousClock.Instant?
    let line: String
}
