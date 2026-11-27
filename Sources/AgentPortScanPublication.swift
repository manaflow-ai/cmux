import Foundation

/// One lifecycle-tokened agent port snapshot queued for MainActor publication.
struct AgentPortScanPublication: Sendable, Equatable {
    let workspaceId: UUID
    let ports: [Int]
    let revision: UInt64
    let requestID: UInt64
    let removesLifecycle: Bool
}
