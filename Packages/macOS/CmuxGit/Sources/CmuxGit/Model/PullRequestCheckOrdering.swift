import Foundation

/// Ordering evidence for two check attempts; ambiguous evidence fails closed.
enum PullRequestCheckOrdering {
    case newer
    case older
    case ambiguous
}
