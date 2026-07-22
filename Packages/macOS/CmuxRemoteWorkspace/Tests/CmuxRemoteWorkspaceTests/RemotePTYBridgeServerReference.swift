import Foundation
@testable import CmuxRemoteWorkspace

/// Synchronous callback handoff used by transport-termination race tests.
/// @unchecked Sendable: the lock guards the sole stored server reference.
final class RemotePTYBridgeServerReference: @unchecked Sendable {
    // The transport termination callback is synchronous, so a tiny lock is
    // the direct handoff; an actor would add a Task hop and lose race ordering.
    private let lock = NSLock()
    private var server: RemotePTYBridgeServer?

    func store(_ server: RemotePTYBridgeServer) {
        lock.withLock {
            self.server = server
        }
    }

    func load() -> RemotePTYBridgeServer? {
        lock.withLock { server }
    }
}
