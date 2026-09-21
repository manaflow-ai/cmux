#if os(iOS)
import Foundation

struct MobileWorkspaceRetryAttempt: Sendable {
    let id: UUID
    let task: Task<Void, Never>
}
#endif
