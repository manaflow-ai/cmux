public import Foundation

/// Immutable pull-request snapshot returned by PRDashboard schema version 1.
public struct GHPRPullRequestContext: Equatable, Sendable {
    public let repository: String
    public let number: Int
    public let title: String
    public let author: String
    public let url: URL?
    public let state: String
    public let isDraft: Bool
    public let isPinned: Bool
    public let hasBaseConflicts: Bool
    public let unresolvedCount: Int
    public let ciStatus: String?
    public let checkSuccessCount: Int
    public let checkFailureCount: Int
    public let checkPendingCount: Int
    public let ciIsRunning: Bool
    public let approvalCount: Int
    public let changesRequestedCount: Int?
    public let myReviewStatus: String?
    public let jiraTicket: String?
    public let updatedAt: String

    public init(
        repository: String,
        number: Int,
        title: String,
        author: String,
        url: URL?,
        state: String,
        isDraft: Bool,
        isPinned: Bool,
        hasBaseConflicts: Bool,
        unresolvedCount: Int,
        ciStatus: String?,
        checkSuccessCount: Int,
        checkFailureCount: Int,
        checkPendingCount: Int,
        ciIsRunning: Bool,
        approvalCount: Int,
        changesRequestedCount: Int?,
        myReviewStatus: String?,
        jiraTicket: String?,
        updatedAt: String
    ) {
        self.repository = repository
        self.number = number
        self.title = title
        self.author = author
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.isPinned = isPinned
        self.hasBaseConflicts = hasBaseConflicts
        self.unresolvedCount = unresolvedCount
        self.ciStatus = ciStatus
        self.checkSuccessCount = checkSuccessCount
        self.checkFailureCount = checkFailureCount
        self.checkPendingCount = checkPendingCount
        self.ciIsRunning = ciIsRunning
        self.approvalCount = approvalCount
        self.changesRequestedCount = changesRequestedCount
        self.myReviewStatus = myReviewStatus
        self.jiraTicket = jiraTicket
        self.updatedAt = updatedAt
    }
}
