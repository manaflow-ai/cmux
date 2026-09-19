import Foundation

struct PullRequestChecksCacheEntry: Sendable {
    let fetchedAt: Date
    let summary: PullRequestChecksSummary
}
