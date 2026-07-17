import Foundation

/// Carries one pending project-root lookup and its continuation.
struct WorktreeSidebarProjectRootRequest: Sendable {
    let requesterID: UUID
    let directory: String
    let continuation: CheckedContinuation<String?, Never>
}
