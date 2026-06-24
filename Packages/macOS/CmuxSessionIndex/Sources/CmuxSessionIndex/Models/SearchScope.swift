public import Foundation

/// What a deep session search (the popover "Show more") filters by.
public enum SearchScope: Sendable {
    case agent(SessionAgent)
    /// Filter by absolute cwd; nil/"" = unknown-folder bucket.
    case directory(String?)
}
