import Combine
import Foundation

/// Per-window presentation mailbox for the sidebar checklist add field. A
/// hidden sidebar claims the latest request when it mounts.
@MainActor
final class WorkspaceTodoChecklistAddRequestStore: ObservableObject {
    struct Request: Equatable {
        let workspaceID: UUID
        let token: UInt64
    }

    @Published private(set) var revision: UInt64 = 0
    private var pendingRequest: Request?
    private var nextToken: UInt64 = 0

    @discardableResult
    func request(workspaceID: UUID) -> UInt64 {
        nextToken &+= 1
        let token = nextToken
        pendingRequest = Request(workspaceID: workspaceID, token: token)
        revision &+= 1
        return token
    }

    /// Atomically removes and returns the request when this sidebar still owns
    /// its workspace. A single add field can own focus, so a newer request
    /// explicitly supersedes an older unclaimed request.
    func claimLatest(workspaceIDs: Set<UUID>) -> Request? {
        guard let pendingRequest,
              workspaceIDs.contains(pendingRequest.workspaceID) else {
            return nil
        }
        self.pendingRequest = nil
        return pendingRequest
    }

    func pendingToken(for workspaceID: UUID) -> UInt64? {
        pendingRequest?.workspaceID == workspaceID ? pendingRequest?.token : nil
    }
}
