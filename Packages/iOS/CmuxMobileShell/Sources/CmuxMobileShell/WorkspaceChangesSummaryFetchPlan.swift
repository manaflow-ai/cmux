internal import Foundation

/// One summary pass plus the fresh entries that need a trailing refresh.
struct WorkspaceChangesSummaryFetchPlan: Sendable, Equatable {
    let batches: [[String]]
    let freshUntilByWorkspaceID: [String: Date]

    var earliestFreshExpiry: Date? {
        freshUntilByWorkspaceID.values.min()
    }
}
