import CmuxNextCompat
public import CmuxNextDaemon

/// Which Home ensure (`HomeService.ensureHomeWorkspace`, numbered by its generation) has its Chief tab step on the
/// Chief owner: waiting for it, then going on with the connection it got.
///
/// CMUX-571 (goal next-launch-instant): on a fresh launch the ensure reached that step and waited; the owner's connect
/// then cancelled it and started a new ensure (ensure_home, the dock steps, the cloud and local Chief reads again), and
/// Home's first page came 1.4-1.7 s after the owner connected (nightly 4370578653101 on a fleet Mac:
/// `home.chief_owner_connected` 2398 ms, `home.chief_owner_ready` 4138 ms). With this record, the connect of the owner
/// that ensure waits for lets it go on (``follows(current:connected:)``); every other connect restarts it as before.
@MainActor
public final class HomeEnsureOwnerWait {
    /// The ensure on the owner, and the owner connection it got (nil while it waits).
    public private(set) var step: (generation: Int, owner: DaemonConnection?)?

    public init() {}

    /// The ensure numbered `generation` waits for `chief` to serve local conversations, and returns its connection
    /// (nil when the wait ended without one). While it waits, and once it has the connection, ``follows`` says so.
    public func connection(of chief: ChiefConversationOwner, generation: Int) async -> DaemonConnection? {
        step = (generation, nil)
        for await connection in ObservationStream({ chief.supports(DaemonCapability.localConversations.rawValue) ? chief.connection : nil }) {
            guard let connection else { continue }
            if step?.generation == generation { step = (generation, connection) }
            return connection
        }
        return nil
    }

    /// The ensure numbered `generation` ended (or a newer one started): it follows no owner any more.
    public func end(_ generation: Int) {
        if step?.generation == generation { step = nil }
    }

    /// Whether the running ensure (`current`) carries on with the owner connection `connected` by itself: it waits
    /// for the owner, or got this very connection. Not when none runs, an older one is recorded, or it holds an
    /// earlier connection of the owner.
    public func follows(current: Int, connected: DaemonConnection) -> Bool {
        guard let step, step.generation == current else { return false }
        return step.owner.map { $0 === connected } ?? true
    }
}
