import Foundation

/// Cancels both readers when the last row/selection stops owning this room.
@MainActor
final class WorkspacePresenceObservation {
    let session: WorkspacePresenceSession
    var snapshotTask: Task<Void, Never>?
    var runTask: Task<Void, Never>?

    init(session: WorkspacePresenceSession) { self.session = session }

    deinit {
        snapshotTask?.cancel()
        runTask?.cancel()
    }

    func stop() {
        snapshotTask?.cancel()
        runTask?.cancel()
        session.stop()
    }
}
