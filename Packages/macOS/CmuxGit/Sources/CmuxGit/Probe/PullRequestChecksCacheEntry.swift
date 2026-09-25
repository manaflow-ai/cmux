import Foundation

/// A request generation and its optional verified result, evicted together.
struct PullRequestChecksCacheEntry: Sendable {
    let generation: UUID
    var fetchedAt: Date
    var summary: PullRequestChecksSummary?
}
